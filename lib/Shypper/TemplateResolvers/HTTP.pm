package Shypper::TemplateResolvers::HTTP;
use Moo;
use utf8;
use Shypper::Logger;
use Furl;
use Digest::MD5 qw/md5_hex/;
use Redis;

has 'logger' => ( is => 'rw', lazy => 1, builder => \&get_logger );

has 'base_url'   => ( is => 'rw' );
has 'headers'   => ( is => 'rw' );
has 'cache_prefix'   => ( is => 'rw', default => 'shypper-template-' );

has '_furl'   => ( is => 'rw', lazy => 1, builder => '_build_furl' );
has '_redis'   => ( is => 'rw', lazy => 1, builder => '_build_redis' );

sub _build_furl {
    Furl->new( timeout => 60, agent => 'Emaildb/TemplateResolversHTTP' );
}

sub _build_redis {
    Redis->new();
}

sub get_template {
    my ( $self, $template)  = @_;

    my $url = $self->base_url;
    $url .='/' unless $url =~ /\/$/;
    $url .= $template;

    my $cachekey = $self->cache_prefix . md5_hex($url);
    my $cached = $self->_redis->get( $cachekey );

    unless ($cached){
        my $headers = $self->headers || [];
        my $res = $self->_furl->get($url, $headers);

    }

    use DDP; p $template;
exit;

}

1;
