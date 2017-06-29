requires 'Furl';
requires 'Moo';
requires 'Log::Log4perl';
requires 'DBIx::Class::Schema::Loader';
requires 'DBD::Pg';
requires 'DBIx::Class::InflateColumn::DateTime';
requires 'Data::Validate::URI';
requires 'Starman';
requires 'Server::Starter';
requires 'Net::Server::SS::PreFork';
requires 'Redis';
requires 'Class::Load';
requires 'Email::Sender';
requires 'Email::MIME::CreateHTML';
requires 'Text::Xslate';
requires 'Parallel::Prefork';

on test => sub {
    requires 'JSON', '2.34';
    requires 'Test::More', '0.96';

    requires 'HTTP::Response';
    requires 'Test::Fake::HTTPD';
    requires 'LWP::UserAgent';
    requires 'URL::Encode', '0.03';
    requires 'Test::Pod';
};