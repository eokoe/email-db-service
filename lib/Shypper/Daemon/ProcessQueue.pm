package Shypper::Daemon::ProcessQueue;
use Moo;
use utf8;
use Shypper::SchemaConnected;
use Shypper::Logger;
use DateTime;
use Shypper::API::Object::HTTPRequest;
use UUID::Tiny qw/is_uuid_string/;
use HTTP::Async;
use HTTP::Request;
use Shypper::TrapSignals;

has 'schema' => ( is => 'rw', lazy => 1, builder => \&GET_SCHEMA );
has 'logger' => ( is => 'rw', lazy => 1, builder => \&get_logger );

has '_email_queue' => (
    is      => 'rw',
    builder => sub {
        shift->schema->resultset('HttpRequest');
    }
);
has '_http_request_status_rs' => (
    is      => 'rw',
    builder => sub {
        shift->schema->resultset('HttpRequestStatus');
    }
);
has '_http_response_rs' => (
    is      => 'rw',
    builder => sub {
        shift->schema->resultset('HttpResponse');
    }
);
use Time::HiRes qw(time);

my $http_ids = {};
has 'ahttp' => ( is => 'rw', lazy => 1, builder => '_build_http' );

sub _build_http {
    HTTP::Async->new( timeout => 60, max_request_time => 120, slots => 1000 );
}

sub pending_jobs {
    my ( $self, %opts ) = @_;

    my @rows = $self->_email_queue->search(
        {

            'me.sent' => 0,

            (
                exists $opts{id_not_in}
                  && ref $opts{id_not_in} eq 'ARRAY' ? ( '-not' => { 'me.id' => { 'in' => $opts{id_not_in} } } ) : ()
              )

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
    return -2 unless $pending;

    my $async = $self->ahttp;

    $self->_prepare_request($pending);

    if ( $async->not_empty ) {
        if ( my ( $response, $iid ) = $async->wait_for_next_response(30) ) {

            # deal with $response
            $self->_set_request_status( res => $response, ref => delete $http_ids->{$iid} );
            return 1;
        }
        else {
            return -1;
        }
    }

    return -2;
}

sub listen_queue {
    my ($self) = @_;

    my $async      = $self->ahttp;
    my $logger     = $self->logger;
    my $loop_times = 0;
    my $dbh        = $self->schema->storage->dbh;

    $logger->info("LISTEN newhttp");
    $dbh->do("LISTEN newhttp");
    eval {
        while (1) {

            if ( $async->empty ) {
                ON_TERM_EXIT;
                EXIT_IF_ASKED;
            }

            ON_TERM_WAIT;
            while ( my $notify = $dbh->pg_notifies ) {
                $loop_times = 0;
            }

            if ( $loop_times == 0 ) {
                my @pendings = $self->pending_jobs( id_not_in => [ map { $http_ids->{$_}{id} } keys %{$http_ids} ] );

                $self->_prepare_request($_) for @pendings;
            }

            if ( $async->not_empty ) {

                while ( my ( $response, $iid ) = $async->next_response ) {

                    my $ref = delete $http_ids->{$iid};
                    $self->logger->debug( join ' ', 'finished', $ref->{id}, 'with code', $response->code );

                    # deal with $response
                    $self->_set_request_status( res => $response, ref => $ref );

                }
            }
            else {
                ON_TERM_EXIT;
                EXIT_IF_ASKED;
            }

            select undef, undef, undef, 0.01;
            $loop_times = 0 if ++$loop_times == 500;
        }
    };

    $logger->fatal("Fatal error: $@") if $@;
}

sub _prepare_request {
    my ( $self, $row ) = @_;
    my @headers = $row->{headers} ? ( map { split /:\s+/, $_, 2 } split /\n/, $row->{headers} ) : ();
    my $async = $self->ahttp;

    $self->logger->debug( join ' ', 'Appending', $row->{method}, $row->{url}, $row->{id}, 'to queue' );

    my $id = $async->add( HTTP::Request->new( uc $row->{method}, $row->{url}, \@headers, $row->{body} ) );
    $http_ids->{$id}{id}   = $row->{id};
    $http_ids->{$id}{time} = time;
    $http_ids->{$id}{try}  = $row->{try_num};

    return $id;
}

sub _set_request_status {
    my ( $self, %opts ) = @_;

    $self->schema->txn_do(
        sub {

            my $ref = $opts{ref};

            $self->_http_response_rs->create(
                {
                    http_request_id => $ref->{id},
                    try_num         => $ref->{try} + 1,
                    took            => ( time - $ref->{time} ) . ' seconds',
                    response        => $opts{res}->as_string
                }
            );

            $self->_http_request_status_rs->update_or_create(
                { done => $opts{res}->code =~ /^2/ ? 1 : 0, try_num => $ref->{try} + 1, http_request_id => $ref->{id} },
                { http_request_id => $ref->{id} }
            );

        }
    );

}

1;
