package Shypper::TemplateResolvers::HTTP;
use Moo;
use utf8;
use strict;
use Shypper;
use Shypper::Logger;
use Furl;
use Digest::MD5 qw/md5_hex/;
use Redis;
use JSON;

has 'logger' => ( is => 'rw', lazy => 1, builder => \&get_logger );

has 'base_url'      => ( is => 'rw' );
has 'headers'       => ( is => 'rw' );
has 'cache_prefix'  => ( is => 'rw', default => 'shypper-template-' );
has 'cache_timeout' => ( is => 'rw', default => '60' );

has 'redis_opts' => ( is => 'rw', default => sub { +{} } );
has 'furl_opts'  => ( is => 'rw', default => sub { +{} } );

has '_furl'  => ( is => 'rw', lazy => 1, builder => '_build_furl' );
has '_redis' => ( is => 'rw', lazy => 1, builder => '_build_redis' );

sub _build_furl {
    Furl->new( timeout => 60, agent => 'Emaildb/TemplateResolversHTTP ' . $Shypper::VERSION, %{ shift->furl_opts() } );
}

sub _build_redis {
    Redis->new( %{ shift->redis_opts() } );
}

sub get_template {
    my ( $self, $template ) = @_;

    my $url = $self->base_url;
    $url .= '/' unless $url =~ /\/$/;
    $url .= $template;

    my $cachekey = $self->cache_prefix . md5_hex($url);
    my $cached   = $self->_redis->get($cachekey);

    unless ($cached) {
        my $headers = $self->headers || [];
        $self->logger->debug("Downloading '$url'");
        my $res = $self->_furl->get( $url, $headers );

        $self->logger->logdie(
            'Downloading template failed ' . encode_json( { map { $_ => $res->$_ } qw/code decoded_content/ } ) )
          unless $res->is_success;

        $cached = $res->decoded_content;
        $self->_redis->setex( $cachekey, $self->cache_timeout, $res->decoded_content );
    }

    return $cached;
}

1;
