use strict;
use warnings;

# test HTTP::HashServer

use Test::More tests => 13;

use MediaWords::Util::Web;

BEGIN
{
    use_ok( 'HTTP::HashServer' );
}

my $_port = 8899;

# verify that a request for the given page on the test server returns the
# given content
sub test_page
{
    my ( $url, $expected_content ) = @_;

    my $ua      = MediaWords::Util::Web::UserAgent->new();
    my $content = $ua->get_string( $url );

    chomp( $content );

    is( $content, $expected_content, "test_page: $url" );
}

sub main
{
    my $pages = {
        '/'          => 'home',
        '/foo'       => 'foo',
        '/bar'       => 'bar',
        '/foo-bar'   => { redirect => '/bar' },
        '/localhost' => { redirect => "http://localhost:$_port/" },
        '/127-foo'   => { redirect => "http://127.0.0.1:$_port/foo" },
        '/auth'      => { auth => 'foo:bar', content => 'foo bar' },
        '/404'       => { content => 'not found', http_status_code => 404 },
    };

    my $hs = HTTP::HashServer->new( $_port, $pages );

    ok( $hs, 'hashserver object returned' );

    $hs->start();

    test_page( "http://localhost:$_port/",          'home' );
    test_page( "http://localhost:$_port/foo",       'foo' );
    test_page( "http://localhost:$_port/bar",       'bar' );
    test_page( "http://localhost:$_port/foo-bar",   'bar' );
    test_page( "http://127.0.0.1:$_port/localhost", 'home' );
    test_page( "http://localhost:$_port/127-foo",   'foo' );

    my $ua = MediaWords::Util::Web::UserAgent->new();

    my $response_404 = $ua->get( "http://localhost:$_port/404" );
    ok( !$response_404->is_success, "404 response should not succeed" );
    is( $response_404->status_line, "404 Not Found", "404 status line" );

    my $auth_url = "http://localhost:$_port/auth";

    my $content = $ua->get_string( $auth_url );
    is( $content, undef, 'fail auth / no auth' );

    my $request = MediaWords::Util::Web::UserAgent::Request->new( 'GET', $auth_url );
    $request->set_authorization_basic( 'foo', 'bar' );
    my $response = $ua->request( $request );
    is( $response->decoded_content, 'foo bar', 'pass auth' );

    $request = MediaWords::Util::Web::UserAgent::Request->new( 'GET', $auth_url );
    $request->set_authorization_basic( 'foo', 'foo' );
    $response = $ua->request( $request );

    is( $response->status_line, "401 Access Denied", 'fail auth / bad password' );

    $hs->stop();
}

main();
