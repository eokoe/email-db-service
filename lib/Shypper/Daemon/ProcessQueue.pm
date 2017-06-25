package Shypper::Daemon::ProcessQueue;
use Moo;
use utf8;
use Shypper::SchemaConnected;
use Shypper::Logger;
use DateTime;
use Shypper::TrapSignals;
use Furl;

has 'schema' => ( is => 'rw', lazy => 1, builder => \&GET_SCHEMA );
has 'logger' => ( is => 'rw', lazy => 1, builder => \&get_logger );

has '_email_queue' => (
    is      => 'rw',
    builder => sub {
        shift->schema->resultset('EmaildbQueue');
    }
);

has 'afurl' => ( is => 'rw', lazy => 1, builder => '_build_furl' );

sub _build_furl {
    Furl->new( timeout => 60 );
}

sub pending_jobs {
    my ( $self, %opts ) = @_;

    my @rows = $self->_email_queue->search(
        {

            'me.sent'    => 0,
            'me.sent_at' => undef
        },
        {
            rows => $opts{rows} ? $opts{rows} : 1000,
            result_class => 'DBIx::Class::ResultClass::HashRefInflator'
        }
    )->all;
    return @rows;
}

sub run_once {
    my ( $self, %opts ) = @_;

    my ($pending) = $self->pending_jobs( rows => 1 );

    # no item on queue
    return -2 unless $pending;

    # ok
    return 1 if $self->_prepare_request($pending);

    # nok
    return -1;
}

sub listen_queue {
    my ($self) = @_;

    my $async      = $self->afurl;
    my $logger     = $self->logger;
    my $loop_times = 0;
    my $dbh        = $self->schema->storage->dbh;

    $logger->info("LISTEN newemail");
    $dbh->do("LISTEN newemail");
    eval {
        while (1) {

            while ( my $notify = $dbh->pg_notifies ) {
                $loop_times = 0;
            }

            if ( $loop_times == 0 ) {
                ON_TERM_WAIT;
                my @pendings = $self->pending_jobs();

                $self->_prepare_request($_) for @pendings;
                ON_TERM_EXIT;
                EXIT_IF_ASKED;
            }

            # sleep for 0.1 sec
            select undef, undef, undef, 0.1;

            # 1/0.1 = 10 = 1 sec, force a query each 60 seconds
            $loop_times = 0 if ++$loop_times == 10 * 60;
        }
    };

    $logger->fatal("Fatal error: $@") if $@;
}

sub _prepare_request {
    my ( $self, $row ) = @_;

    my $ok = 1;

    $self->schema->txn_do(
        sub {

        }
    );

    return $ok;
}

1;
