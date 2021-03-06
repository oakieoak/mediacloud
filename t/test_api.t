#!/usr/bin/env perl

# general test of api end popints

use strict;
use warnings;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../../lib";

}

use Modern::Perl '2015';
use MediaWords::CommonLibs;

use HTTP::HashServer;
use Readonly;
use Test::More;
use Test::Deep;

use MediaWords::DBI::Media::Health;
use MediaWords::DBI::Stats;
use MediaWords::Test::API;
use MediaWords::Test::DB;
use MediaWords::Test::Solr;
use MediaWords::Test::Supervisor;
use MediaWords::Util::Tags;
use MediaWords::Util::Web;

Readonly my $NUM_MEDIA            => 5;
Readonly my $NUM_FEEDS_PER_MEDIUM => 2;
Readonly my $NUM_STORIES_PER_FEED => 10;

# test that a story has the expected content
sub test_story_fields($$$)
{
    my ( $db, $story, $label ) = @_;

    my $expected_story = $db->require_by_id( 'stories', $story->{ stories_id } );

    my $fields = [ qw/stories_id url guid language publish_date media_id title collect_date/ ];
    map { is( $story->{ $_ }, $expected_story->{ $_ }, "$label field '$_'" ) } @{ $fields };
}

# various tests to validate stories_public/list
sub test_stories_public_list($$)
{
    my ( $db, $test_media ) = @_;

    my $stories = test_get( '/api/v2/stories_public/list', { q => 'title:story*', rows => 100000 } );

    my $expected_num_stories = $NUM_MEDIA * $NUM_FEEDS_PER_MEDIUM * $NUM_STORIES_PER_FEED;
    my $got_num_stories      = scalar( @{ $stories } );
    is( $got_num_stories, $expected_num_stories, "stories_public/list: number of stories" );

    my $title_stories_lookup = {};
    my $expected_stories = [ grep { $_->{ stories_id } } values( %{ $test_media } ) ];
    map { $title_stories_lookup->{ $_->{ title } } = $_ } @{ $expected_stories };

    for my $i ( 0 .. $expected_num_stories - 1 )
    {
        my $expected_title = "story story_$i";
        my $found_story    = $title_stories_lookup->{ $expected_title };
        ok( $found_story, "found story with title '$expected_title'" );
        test_story_fields( $db, $stories->[ $i ], "all stories: story $i" );
    }

    my $search_result =
      test_get( '/api/v2/stories_public/list', { q => 'stories_id:' . $stories->[ 0 ]->{ stories_id } } );
    is( scalar( @{ $search_result } ), 1, "stories_public search: count" );
    is( $search_result->[ 0 ]->{ stories_id }, $stories->[ 0 ]->{ stories_id }, "stories_public search: stories_id match" );
    test_story_fields( $db, $search_result->[ 0 ], "story_public search" );

    my $stories_single = test_get( '/api/v2/stories_public/single/' . $stories->[ 1 ]->{ stories_id } );
    is( scalar( @{ $stories_single } ), 1, "stories_public/single: count" );
    is( $stories_single->[ 0 ]->{ stories_id }, $stories->[ 1 ]->{ stories_id }, "stories_public/single: stories_id match" );
    test_story_fields( $db, $search_result->[ 0 ], "stories_public/single" );

    # test feeds_id= param

    # expect error when including q= and feeds_id=
    test_get( '/api/v2/stories_public/list', { q => 'foo', feeds_id => 1 }, 1 );

    my $feed =
      $db->query( "select * from feeds where feeds_id in ( select feeds_id from feeds_stories_map ) limit 1" )->hash;
    my $feed_stories =
      test_get( '/api/v2/stories_public/list', { rows => 100000, feeds_id => $feed->{ feeds_id }, show_feeds => 1 } );
    my $expected_feed_stories = $db->query( <<SQL, $feed->{ feeds_id } )->hashes;
select s.* from stories s join feeds_stories_map fsm using ( stories_id ) where feeds_id = ?
SQL

    is( scalar( @{ $feed_stories } ), scalar( @{ $expected_feed_stories } ), "stories feed count feed $feed->{ feeds_id }" );
    for my $feed_story ( @{ $feed_stories } )
    {
        my ( $expected_story ) = grep { $_->{ stories_id } eq $feed_story->{ stories_id } } @{ $expected_feed_stories };
        ok( $expected_story,
            "stories feed story $feed_story->{ stories_id } feed $feed->{ feeds_id } matches expected story" );
        is( scalar( @{ $feed_story->{ feeds } } ), 1, "stories feed one feed returned" );
        for my $field ( qw/name url feeds_id media_id feed_type/ )
        {
            is( $feed_story->{ feeds }->[ 0 ]->{ $field }, $feed->{ $field }, "feed story field $field" );
        }
    }
}

sub test_stories_count($)
{
    my ( $db ) = @_;

    my $stories = $db->query( "select * from stories order by stories_id asc limit 23" )->hashes;

    my $stories_ids_list = join( ' ', map { $_->{ stories_id } } @{ $stories } );

    my $r = test_get( '/api/v2/stories/count', { q => "stories_id:($stories_ids_list)" } );

    is( $r->{ count }, scalar( @{ $stories } ), "stories/count count" );

    $r = test_get( '/api/v2/stories_public/count', { q => "stories_id:($stories_ids_list)" } );

    is( $r->{ count }, scalar( @{ $stories } ), "stories/count count" );

}

# test auth/profile call
sub test_auth_profile($)
{
    my ( $db ) = @_;

    my $api_token = MediaWords::Test::API::get_test_api_key();

    my $expected_user = $db->query( <<SQL, $api_token )->hash;
select * from auth_users au join auth_user_limits using ( auth_users_id ) where api_token = \$1
SQL
    my $profile = test_get( "/api/v2/auth/profile" );

    for my $field ( qw/email auth_users_id weekly_request_items_limit notes active weekly_requests_limit/ )
    {
        is( $profile->{ $field }, $expected_user->{ $field }, "auth profile $field" );
    }
}

# test auth/single
sub test_auth_single($)
{
    my ( $db ) = @_;

    my $label = "auth/single";

    my $email    = 'test@auth.single';
    my $password = 'authsingle';

    my $error = MediaWords::DBI::Auth::add_user_or_return_error_message( $db, $email, 'auth single', '', [ 1 ], 1, $password,
        $password, 1000, 1000 );

    my $r = test_get( '/api/v2/auth/single', { username => $email, password => $password } );

    my $db_token = $db->query( <<SQL )->hash;
select * from auth_user_ip_tokens order by auth_user_ip_tokens_id desc limit 1
SQL

    is( $r->[ 0 ]->{ result }, 'found', "$label token found" );
    is( $r->[ 0 ]->{ token }, $db_token->{ api_token }, "$label token" );
    is( $db_token->{ ip_address }, '127.0.0.1' );

    my $r_not_found = test_get( '/api/v2/auth/single', { username => $email, password => "$password FOO" } );

    is( $r_not_found->[ 0 ]->{ result }, "not found", "$label status for wrong password" );
}

# test auth/* calls
sub test_auth($)
{
    my ( $db ) = @_;

    test_auth_profile( $db );
    test_auth_single( $db );
}

# test that the values at the given fields are equal in each hash, using the given test label
sub _compare_fields($$$$)
{
    my ( $label, $got, $expected, $fields ) = @_;

    for my $field ( @{ $fields } )
    {
        is( $got->{ $field }, $expected->{ $field }, "$label $field" );
    }
}

# wait for feed scraping to happen and verify that a valid feed has been discovered for each site
sub test_for_scraped_feeds($$)
{
    my ( $db, $sites ) = @_;

    my $timeout = 90;
    my $i       = 0;
    while ( $i++ < $timeout )
    {
        my ( $num_waiting_media ) =
          $db->query( "select count(*) from media_rescraping where last_rescrape_time is null" )->flat;
        ( $num_waiting_media > 0 ) ? sleep 1 : last;
        DEBUG( "wait for feed scraping ($num_waiting_media) ..." );
    }

    ok( 0, "timed out waiting for scraped feeds" ) if ( $i == $timeout );

    for my $site ( @{ $sites } )
    {
        my $medium = $db->query( "select * from media where name = ?", $site->{ name } )->hash
          || die( "unable to find medium for site $site->{ name }" );
        my $feed = $db->query( "select * from feeds where media_id = ?", $medium->{ media_id } )->hash;
        ok( $feed, "feed exists for site $site->{ name } media_id $medium->{ media_id }" );
        is( $feed->{ feed_type },   'syndicated',        "$site->{ name } feed type" );
        is( $feed->{ feed_status }, 'active',            "$site->{ name } feed status" );
        is( $feed->{ url },         $site->{ feed_url }, "$site->{ name } feed url" );
    }
}

# start a HTTP::HashServer with the following pages for each of the given site names:
# * home page - http://localhost:$port/$site
# * feed page - http://localhost:$port/$site/feed
# * custom feed page - http://localhost:$port/$site/custom_feed
#
# return the HTTP::HashServer
sub start_media_create_hash_server
{
    my ( $site_names ) = @_;

    my $port = 8976;

    my $pages = {};
    for my $site_name ( @{ $site_names } )
    {
        $pages->{ "/$site_name" } = "<html><title>$site_name</title><body>$site_name body</body>";

        my $atom = <<ATOM;
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
	<title>$site_name</title>
	<link href="http://localhost:$port/$site_name" />
	<id>urn:uuid:60a76c80-d399-11d9-b91C-0003939e0af6</id>
	<updated>2015-12-13T18:30:02Z</updated>
	<entry>
		<title>$site_name page</title>
		<link href="http://localhost:$port/$site_name/page" />
		<id>urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a</id>
		<updated>2015-12-13T18:30:02Z</updated>
	</entry>
</feed>
ATOM

        $pages->{ "/$site_name/feed" }        = { header => 'Content-Type: application/atom+xml', content => $atom };
        $pages->{ "/$site_name/custom_feed" } = { header => 'Content-Type: application/atom+xml', content => $atom };
    }

    my $hs = HTTP::HashServer->new( $port, $pages );

    $hs->start();

    return $hs;
}

# test that the feeds and tags_ids fields update existing media sources when passed to create
sub test_media_create_update($$)
{
    my ( $db, $sites ) = @_;

    my $tag = MediaWords::Util::Tags::lookup_or_create_tag( $db, 'media_test:media_test' );

    my $input = [
        map {
            {
                url      => $_->{ url },
                tags_ids => [ $tag->{ tags_id } ],
                feeds    => [ $_->{ feed_url }, $_->{ custom_feed_url }, 'http://127.0.0.1:123456/456789/feed' ]
            }
        } @{ $sites }
    ];

    my $r = test_post( '/api/v2/media/create', $input );

    my $got_media_ids = [ map { $_->{ media_id } } grep { $_->{ status } ne 'error' } @{ $r } ];
    is( scalar( @{ $got_media_ids } ), scalar( @{ $sites } ), "media/create update media returned" );

    for my $site ( @{ $sites } )
    {
        my $medium = $db->query( "select * from media where name = ?", $site->{ name } )->hash
          || die( "unable to find medium for site $site->{ name }" );
        my $feeds = $db->query( "select * from feeds where media_id = ? order by feeds_id", $medium->{ media_id } )->hashes;
        is( scalar( @{ $feeds } ), 2, "media/create update $site->{ name } num feeds" );

        is( $feeds->[ 0 ]->{ url }, $site->{ feed_url },        "media/create update $site->{ name } default feed url" );
        is( $feeds->[ 1 ]->{ url }, $site->{ custom_feed_url }, "media/create update $site->{ name } custom feed url" );

        for my $feed ( @{ $feeds } )
        {
            is( $feed->{ feed_type },   'syndicated', "$site->{ name } feed type" );
            is( $feed->{ feed_status }, 'active',     "$site->{ name } feed status" );
        }

        my ( $tag_exists ) = $db->query( <<SQL, $medium->{ media_id }, $tag->{ tags_id } )->flat;
select * from media_tags_map where media_id = \$1 and tags_id = \$2
SQL
        ok( $tag_exists, "media/create update $site->{ name } tag exists" );
    }
}

# test media/update call
sub test_media_update($$)
{
    my ( $db, $sites ) = @_;

    # test that request with no media_id returns an error
    test_put( '/api/v2/media/update', {}, 1 );

    # test that request with list returns an error
    test_put( '/api/v2/media/update', [ { media_id => 1 } ], 1 );

    my $medium = $db->query( "select * from media where name = ?", $sites->[ 0 ]->{ name } )->hash;

    my $fields = [ qw/media_id name url content_delay editor_notes public_notes foreign_rss_links/ ];

    # test just name change
    my $r = test_put( '/api/v2/media/update', { media_id => $medium->{ media_id }, name => "$medium->{ name } FOO" } );
    is( $r->{ success }, 1, "media/update name success" );

    my $updated_medium = $db->require_by_id( 'media', $medium->{ media_id } );
    is( $updated_medium->{ name }, "$medium->{ name } FOO", "media update name" );
    $medium->{ name } = $updated_medium->{ name };
    map { is( $updated_medium->{ $_ }, $medium->{ $_ }, "media update name field $_" ) } @{ $fields };

    # test all other fields
    $medium = {
        media_id          => $medium->{ media_id },
        url               => "http://url.update/",
        name              => 'name update',
        foreign_rss_links => 1,
        content_delay     => 100,
        editor_notes      => 'editor_notes update',
        public_notes      => 'public_notes update'
    };

    $r = test_put( '/api/v2/media/update', $medium );
    is( $r->{ success }, 1, "media/update all success" );

    $updated_medium = $db->require_by_id( 'media', $medium->{ media_id } );
    map { is( $updated_medium->{ $_ }, $medium->{ $_ }, "media update name field $_" ) } @{ $fields };
}

# test media/create  end point
sub test_media_create($)
{
    my ( $db ) = @_;

    my $site_names = [ map { "media_create_site_$_" } ( 1 .. 5 ) ];

    my $hs = start_media_create_hash_server( $site_names );

    my $sites = [];
    for my $site_name ( @{ $site_names } )
    {
        push(
            @{ $sites },
            {
                name            => $site_name,
                url             => $hs->page_url( $site_name ),
                feed_url        => $hs->page_url( "$site_name/feed" ),
                custom_feed_url => $hs->page_url( "$site_name/custom_feed" )
            }
        );
    }

    # delete existing entries in media_rescraping so that we can wait for it to be empty in test_for_scraped_feeds()
    $db->query( "truncate table media_rescraping" );

    # test that non-list returns an error
    test_post( '/api/v2/media/create', {}, 1 );

    # test that single element without url returns an error
    test_post( '/api/v2/media/create', [ { url => 'http://foo.com' }, { name => "bar" } ], 1 );

    # simple test for creation of url only medium
    my $first_site = $sites->[ 0 ];
    my $r = test_post( '/api/v2/media/create', [ { url => $first_site->{ url } } ] );

    is( scalar( @{ $r } ),     1,                    "media/create url number of statuses" );
    is( $r->[ 0 ]->{ status }, 'new',                "media/create url status" );
    is( $r->[ 0 ]->{ url },    $first_site->{ url }, "media/create url url" );

    my $first_medium = $db->query( "select * from media where name = \$1", $first_site->{ name } )->hash;
    ok( $first_medium, "media/create url found medium with matching title" );

    # test that create reuse the same media source we just created
    $r = test_post( '/api/v2/media/create', [ { url => $first_site->{ url } } ] );
    is( scalar( @{ $r } ),       1,                           "media/create existing number of statuses" );
    is( $r->[ 0 ]->{ status },   'existing',                  "media/create existing status" );
    is( $r->[ 0 ]->{ url },      $first_site->{ url },        "media/create existing url" );
    is( $r->[ 0 ]->{ media_id }, $first_medium->{ media_id }, "media/create existing media_id" );

    # add all media sources in sites, plus one which should return a 404
    my $input = [ map { { url => $_->{ url } } } ( @{ $sites }, { url => 'http://127.0.0.1:123456/456789' } ) ];
    $r = test_post( '/api/v2/media/create', $input );
    my $status_media_ids = [ map { $_->{ media_id } } grep { $_->{ status } ne 'error' } @{ $r } ];
    my $status_errors    = [ map { $_->{ error } } grep    { $_->{ status } eq 'error' } @{ $r } ];

    is( scalar( @{ $status_media_ids } ), scalar( @{ $sites } ), "media/create mixed urls number returned" );
    is( scalar( @{ $status_errors } ), 1, "media/create mixed urls errors returned" );
    ok( $status_errors->[ 0 ] =~ /Unable to fetch medium url/, "media/create mixed urls error message" );

    for my $site ( @{ $sites } )
    {
        my $url = $site->{ url };
        my $db_m = $db->query( "select * from media where url = ?", $url )->hash;
        ok( $db_m, "media/create mixed urls medium found for in db url $url" );
        ok( grep { $_ == $db_m->{ media_id } } @{ $status_media_ids } );
    }

    test_for_scraped_feeds( $db, $sites );

    test_media_create_update( $db, $sites );

    test_media_update( $db, $sites );

    $hs->stop();
}

# test that the media/list call with the given params returns precisely the list of expected media
sub test_media_list_call($$)
{
    my ( $params, $expected_media ) = @_;

    my $d = Data::Dumper->new( [ $params ] );
    $d->Terse( 1 );
    my $label = "media/list with params " . $d->Dump;

    my $got_media = test_get( '/api/v2/media/list', $params );
    is( scalar( @{ $got_media } ), scalar( @{ $expected_media } ), "$label number of media" );
    for my $got_medium ( @{ $got_media } )
    {
        my ( $expected_medium ) = grep { $_->{ media_id } eq $got_medium->{ media_id } } @{ $expected_media };
        ok( $expected_medium, "$label medium $got_medium->{ media_id } expected" );

        my $fields = [ qw/name url is_healthy is_monitored editor_notes public_notes/ ];
        map { ok( defined( $got_medium->{ $_ } ), "$label field $_ defined" ) } @{ $fields };
        map { is( $got_medium->{ $_ }, $expected_medium->{ $_ }, "$label field $_" ) } @{ $fields };

        is(
            $got_medium->{ primary_language }      || 'null',
            $expected_medium->{ primary_language } || 'null',
            "$label field primary language"
        );
    }
}

# test the media/list call
sub test_media_list ($$)
{
    my ( $db, $test_stack ) = @_;

    my $test_stack_media = [ grep { defined( $_->{ foreign_rss_links } ) } values( %{ $test_stack } ) ];
    die( "no media found: " . Dumper( $test_stack ) ) unless ( @{ $test_stack_media } );

    # this has to be done first so that media_health exists
    map { $_->{ is_healthy } = 1 } @{ $test_stack_media };
    my $unhealthy_medium = $test_stack_media->[ 2 ];
    $unhealthy_medium->{ is_healthy } = 0;
    MediaWords::DBI::Media::Health::generate_media_health( $db );
    $db->query( "update media_health set is_healthy = ( media_id <> \$1 )", $unhealthy_medium->{ media_id } );
    test_media_list_call( { unhealthy => 1 }, [ $unhealthy_medium ] );

    test_media_list_call( {}, $test_stack_media );

    my $single_medium = $test_stack_media->[ 0 ];
    test_media_list_call( { name => $single_medium->{ name } }, [ $single_medium ] );

    my $got_single_medium = test_get( '/api/v2/media/single/' . $single_medium->{ media_id }, {} );
    my $fields = [ qw/name url is_healthy is_monitored editor_notes public_notes/ ];
    rows_match( $db, $got_single_medium, [ $single_medium ], 'media_id', $fields );

    my $tagged_medium = $test_stack_media->[ 1 ];
    my $test_tag = MediaWords::Util::Tags::lookup_or_create_tag( $db, 'media_list_test:media_list_test' );
    $db->update_by_id( 'tags', $test_tag->{ tags_id }, { show_on_media => 't' } );
    $db->create( 'media_tags_map', { tags_id => $test_tag->{ tags_id }, media_id => $tagged_medium->{ media_id } } );
    test_media_list_call( { tag_name => $test_tag->{ tag } }, [ $tagged_medium ] );

    my $similar_medium = $test_stack_media->[ 2 ];
    $db->create( 'media_tags_map', { tags_id => $test_tag->{ tags_id }, media_id => $similar_medium->{ media_id } } );
    test_media_list_call( { similar_media_id => $tagged_medium->{ media_id } }, [ $similar_medium ] );

    my $english_medium = $test_stack_media->[ 1 ];
    $db->query( "update media set primary_language = 'en' where media_id = \$1", $english_medium->{ media_id } );
    $english_medium->{ primary_language } = 'en';
    test_media_list_call( { primary_language => 'en' }, [ $english_medium ] );

}

# test various media/ calls
sub test_media($$)
{
    my ( $db, $test_media ) = @_;

    test_media_list( $db, $test_media );

    test_media_create( $db );
}

# given the response from an api call, fetch the referred row from the given table in the database
# and verify that the fields in the given input match what's in the database
sub validate_db_row($$$$$)
{
    my ( $db, $table, $response, $input, $label ) = @_;

    my $id_field = "${ table }_id";

    ok( $response->{ $id_field } > 0, "$label $id_field returned" );
    my $db_row = $db->find_by_id( $table, $response->{ $id_field } );
    ok( $db_row, "$label row found in db" );
    map { is( $db_row->{ $_ }, $input->{ $_ }, "$label field $_" ) } keys( %{ $input } );
}

# return tag in either { tags_id => $tags_id }or { tag => $tag, tag_set => $tag_set } form depending on $input_form
sub get_put_tag_input_tag($$$)
{
    my ( $tag, $tag_set, $input_form ) = @_;

    if ( $input_form eq 'id' )
    {
        return { tags_id => $tag->{ tags_id } };
    }
    elsif ( $input_form eq 'name' )
    {
        return { tag => $tag->{ tag }, tag_set => $tag_set->{ name } };
    }
    else
    {
        die( "unknown input_form '$input_form'" );
    }
}

# given a set of tags, return a list of hashes in the proper form for a put_tags call
sub get_put_tag_input_records($$$$$$)
{
    my ( $db, $table, $rows, $tag_sets, $input_form, $action ) = @_;

    my $id_field = $table . "_id";

    my $input = [];
    for my $add_tag_set ( @{ $tag_sets } )
    {
        for my $add_tag ( @{ $add_tag_set->{ add_tags } } )
        {
            for my $row ( @{ $rows } )
            {
                my $put_tag = get_put_tag_input_tag( $add_tag, $add_tag_set, $input_form );
                $put_tag->{ $id_field } = $row->{ $id_field };
                $put_tag->{ action } = $action;

                push( @{ $input }, $put_tag );
            }
        }
    }

    return $input;
}

# get the url for the put_tag end point for the given table
sub get_put_tag_url($;$)
{
    my ( $table, $clear ) = @_;

    my $url = ( $table eq 'story_sentences' ) ? '/api/v2/sentences/put_tags' : "/api/v2/$table/put_tags";

    $url .= '?clear_tag_sets=1' if ( $clear );

    return $url;
}

# test using put_tags to add the given tags to the given rows in the given table.
sub test_add_tags
{
    my ( $db, $table, $rows, $tag_sets, $input_form, $clear ) = @_;

    my $num_add_tag_sets = int( scalar( @{ $tag_sets } ) / 2 );
    my $num_add_tags     = int( scalar( @{ $tag_sets->[ 0 ]->{ tags } } ) / 2 );

    my $add_tag_sets = [ @{ $tag_sets }[ 0 .. $num_add_tag_sets - 1 ] ];
    map { $_->{ add_tags } = [ @{ $_->{ tags } }[ 0 .. $num_add_tags - 1 ] ] } @{ $add_tag_sets };

    my $put_tags = get_put_tag_input_records( $db, $table, $rows, $add_tag_sets, $input_form, 'add' );

    my $r = test_put( get_put_tag_url( $table, $clear ), $put_tags );

    my $map_table    = $table . "_tags_map";
    my $id_field     = $table . "_id";
    my $row_ids      = [ map { $_->{ $id_field } } @{ $rows } ];
    my $row_ids_list = join( ',', @{ $row_ids } );

    my $add_tags = [];
    map { push( @{ $add_tags }, @{ $_->{ add_tags } } ) } @{ $add_tag_sets };

    my $clear_label = $clear ? 'clear' : 'no clear';
    my $label =
      "test add tags $table with $clear_label input $input_form [" .
      scalar( @{ $rows } ) . " rows / " .
      scalar( @{ $add_tags } ) . " add tags]";

    my $tags_ids_list = join( ',', map { $_->{ tags_id } } @{ $add_tags } );

    my ( $map_count ) = $db->query( <<SQL )->flat;
select count(*) from $map_table where $id_field in ( $row_ids_list ) and tags_id in ( $tags_ids_list )
SQL

    my $expected_map_count = scalar( @{ $rows } ) * scalar( @{ $add_tags } );
    is( $map_count, $expected_map_count, "$label map count" );

    my $maps = $db->query( <<SQL )->hashes;
select * from $map_table where $id_field in ( $row_ids_list ) and tags_id in ( $tags_ids_list )
SQL
    for my $map ( @{ $maps } )
    {
        my $row_expected = grep { $map->{ $id_field } == $_->{ $id_field } } @{ $rows };
        ok( $row_expected, "$label expected row $map->{ $id_field }" );

        my $tag_expected = grep { $map->{ $id_field } == $_->{ $id_field } } @{ $rows };
        ok( $tag_expected, "$label expected tag $map->{ tags_id }" );
    }

    # clean up so the next test has a clean slate
    $db->query( "delete from $map_table where $id_field in ( $row_ids_list ) and tags_id in ( $tags_ids_list )" );
}

# test removing tag associations
sub test_remove_tags
{
    my ( $db, $table, $rows, $tag_sets, $input_form ) = @_;

    my $map_table         = $table . "_tags_map";
    my $id_field          = $table . "_id";
    my $row_ids           = [ map { $_->{ $id_field } } @{ $rows } ];
    my $row_ids_list      = join( ',', @{ $row_ids } );
    my $tag_sets_ids_list = join( ',', map { $_->{ tag_sets_id } } @{ $tag_sets } );

    my $label = "test remove tags $table input $input_form";

    for my $row ( @{ $rows } )
    {
        $db->query( <<SQL, $row->{ $id_field } );
insert into $map_table ( $id_field, tags_id )
        select \$1, tags_id from tags where tag_sets_id in ( $tag_sets_ids_list )
SQL
    }

    map { $_->{ add_tags } = [ $_->{ tags }->[ 0 ] ] } @{ $tag_sets };

    my $put_tags = get_put_tag_input_records( $db, $table, $rows, $tag_sets, $input_form, 'remove' );
    my $r = test_put( get_put_tag_url( $table ), $put_tags );

    my $expected_map_count =
      scalar( @{ $tag_sets } ) * ( scalar( @{ $tag_sets->[ 0 ]->{ tags } } ) - 1 ) * scalar( @{ $rows } );

    my ( $map_count ) = $db->query( <<SQL )->flat;
select count(*)
    from $map_table join tags using ( tags_id )
    where $id_field in ( $row_ids_list ) and tag_sets_id in ( $tag_sets_ids_list )
SQL
    is( $map_count, $expected_map_count, "$label map count" );

    # clean up so the next test has a clean slate
    $db->query( <<SQL );
delete from $map_table
    using tags
    where $map_table.tags_id = tags.tags_id and
        $id_field in ( $row_ids_list ) and
        tag_sets_id in ( $tag_sets_ids_list )
SQL
}

# add all tags to the map, use the clear_tags= param, then make sure only added tags are associated
sub test_clear_tags($$$$$)
{
    my ( $db, $table, $rows, $tag_sets, $input_form ) = @_;

    my $map_table = $table . "_tags_map";
    my $id_field  = $table . "_id";

    my $tag_sets_ids_list = join( ',', map { $_->{ tag_sets_id } } @{ $tag_sets } );

    for my $row ( @{ $rows } )
    {
        $db->query( <<SQL, $row->{ $id_field } );
insert into $map_table ( $id_field, tags_id )
        select \$1, tags_id from tags where tag_sets_id in ( $tag_sets_ids_list )
SQL
    }

    test_add_tags( $db, $table, $rows, $tag_sets, $input_form, 1 );
}

# test /apiv/2/$table/put_tags call.  assumes that there are at least three rows in $table, which there should be
# from the create_test_story_stack() call
sub test_put_tags($$)
{
    my ( $db, $table ) = @_;

    my $url      = get_put_tag_url( $table );
    my $id_field = $table . "_id";

    my $num_tag_sets = 5;
    my $num_tags     = 10;

    my $tag_sets = [];
    for my $i ( 1 .. $num_tag_sets )
    {
        my $tag_set = $db->find_or_create( 'tag_sets', { name => "put tags $i" } );
        for my $i ( 1 .. $num_tags )
        {
            my $tag = $db->find_or_create( 'tags', { tag => "tag $i", tag_sets_id => $tag_set->{ tag_sets_id } } );
            push( @{ $tag_set->{ tags } }, $tag );
        }
        push( @{ $tag_sets }, $tag_set );
    }

    my $first_tags_id = $tag_sets->[ 0 ]->{ tags }->[ 0 ];

    my $num_rows = 3;
    my $rows     = $db->query( "select * from $table limit $num_rows" )->hashes;

    my $first_row_id = $rows->[ 0 ]->{ "${ table }_id" };

    # test that api recognizes various errors
    test_put( $url, {}, 1 );    # require list
    test_put( $url, [ [] ], 1 );    # require list of records
    test_put( $url, [ { tags_id   => $first_tags_id } ], 1 );    # require id
    test_put( $url, [ { $id_field => $first_row_id } ],  1 );    # require tag

    test_add_tags( $db, $table, $rows, $tag_sets, 'id' );
    test_add_tags( $db, $table, $rows, $tag_sets, 'name' );
    test_remove_tags( $db, $table, $rows, $tag_sets, 'id' );

    test_clear_tags( $db, $table, $rows, $tag_sets, 'id' );
}

# test tags/list
sub test_tags_list($)
{
    my ( $db ) = @_;

    my $num_tags = 10;
    my $label    = "tags list";

    my $tag_set     = $db->create( 'tag_sets', { name => 'tag list test' } );
    my $tag_sets_id = $tag_set->{ tag_sets_id };
    my $input_tags  = [ map { { tag => "tag $_", label => "tag $_", tag_sets_id => $tag_sets_id } } ( 1 .. $num_tags ) ];
    map { test_post( '/api/v2/tags/create', $_ ) } @{ $input_tags };

    # query by tag_sets_id
    my $got_tags = test_get( '/api/v2/tags/list', { tag_sets_id => $tag_sets_id } );
    is( scalar( @{ $got_tags } ), $num_tags, "$label number of tags" );

    for my $got_tag ( @{ $got_tags } )
    {
        my ( $input_tag ) = grep { $got_tag->{ tag } eq $_->{ tag } } @{ $input_tags };
        ok( $input_tag, "$label found input tag" );
        map { is( $got_tag->{ $_ }, $input_tag->{ $_ }, "$label field $_" ) } keys( %{ $input_tag } );
    }

    my ( $t0, $t1, $t2, $t3 ) = @{ $got_tags };

    # test public= query
    test_put( '/api/v2/tags/update', { tags_id => $t0->{ tags_id }, show_on_media   => 1 } );
    test_put( '/api/v2/tags/update', { tags_id => $t1->{ tags_id }, show_on_stories => 1 } );
    my $got_public_tags = test_get( '/api/v2/tags/list', { public => 1, tag_sets_id => $tag_sets_id } );
    is( scalar( @{ $got_public_tags } ), 2, "$label show_on_media count" );
    ok( ( grep { $_->{ tags_id } == $t0->{ tags_id } } @{ $got_public_tags } ), "$label public show_on_media" );
    ok( ( grep { $_->{ tags_id } == $t1->{ tags_id } } @{ $got_public_tags } ), "$label public show_on_stories" );

    # test similar_tags_id
    my $medium = $db->query( "select * from media limit 1" )->hash;
    map { $db->create( 'media_tags_map', { media_id => $medium->{ media_id }, tags_id => $_->{ tags_id } } ) }
      ( $t0, $t1, $t2 );
    my $got_similar_tags = test_get( '/api/v2/tags/list', { similar_tags_id => $t0->{ tags_id } } );
    is( scalar( @{ $got_similar_tags } ), 2, "$label similar count" );
    ok( ( grep { $_->{ tags_id } == $t1->{ tags_id } } @{ $got_similar_tags } ), "$label similar tags_id t1" );
    ok( ( grep { $_->{ tags_id } == $t2->{ tags_id } } @{ $got_similar_tags } ), "$label simlar tags_id t2" );
}

# test tags/single
sub test_tags_single($)
{
    my ( $db ) = @_;

    my $label = "tags/single";

    my $expected_tag = $db->query( "select * from tags order by tags_id limit 1" )->hash;

    my $got_tags = test_get( '/api/v2/tags/single/' . $expected_tag->{ tags_id } );

    my $got_tag = $got_tags->[ 0 ];

    ok( $got_tag, "$label found tag" );

    my $fields = [ qw/tags_id tag_sets_id tag label description show_on_media show_on_stories is_static/ ];
    map { is( $got_tag->{ $_ }, $expected_tag->{ $_ }, "$label field $_" ) } @{ $fields };
}

# test tags create, update, list, and association
sub test_tags($)
{
    my ( $db ) = @_;

    # test for required fields errors
    test_post( '/api/v2/tags/create', { tag   => 'foo' }, 1 );    # should require label
    test_post( '/api/v2/tags/create', { label => 'foo' }, 1 );    # should require tag
    test_put( '/api/v2/tags/update', { tag => 'foo' }, 1 );       # should require tags_id

    my $tag_set = $db->create( 'tag_sets', { name => 'foo tag set' } );

    # simple tag creation
    my $create_input = {
        tag_sets_id     => $tag_set->{ tag_sets_id },
        tag             => 'foo tag',
        label           => 'foo label',
        description     => 'foo description',
        show_on_media   => 1,
        show_on_stories => 1,
        is_static       => 1
    };

    my $r = test_post( '/api/v2/tags/create', $create_input );
    validate_db_row( $db, 'tags', $r->{ tag }, $create_input, 'create tag' );

    # error on update non-existent tag
    test_put( '/api/v2/tags/update', { tags_id => -1 }, 1 );

    # simple update
    my $update_input = {
        tags_id         => $r->{ tag }->{ tags_id },
        tag             => 'bar tag',
        label           => 'bar label',
        description     => 'bar description',
        show_on_media   => 0,
        show_on_stories => 0,
        is_static       => 0
    };

    $r = test_put( '/api/v2/tags/update', $update_input );
    validate_db_row( $db, 'tags', $r->{ tag }, $update_input, 'update tag' );

    # simple tags/list test
    test_tags_list( $db );
    test_tags_single( $db );

    # test put_tags calls on all tables
    test_put_tags( $db, 'stories' );
    test_put_tags( $db, 'story_sentences' );
    test_put_tags( $db, 'media' );

}

# test tag set create, update, and list
sub test_tag_sets($)
{
    my ( $db ) = @_;

    # test for required fields errors
    test_post( '/api/v2/tag_sets/create', { name  => 'foo' }, 1 );    # should require label
    test_post( '/api/v2/tag_sets/create', { label => 'foo' }, 1 );    # should require name
    test_put( '/api/v2/tag_sets/update', { name => 'foo' }, 1 );      # should require tag_sets_id

    # simple tag creation
    my $create_input = {
        name            => 'fooz tag set',
        label           => 'fooz label',
        description     => 'fooz description',
        show_on_media   => 1,
        show_on_stories => 1,
    };

    my $r = test_post( '/api/v2/tag_sets/create', $create_input );
    validate_db_row( $db, 'tag_sets', $r->{ tag_set }, $create_input, 'create tag set' );

    # error on update non-existent tag
    test_put( '/api/v2/tag_sets/update', { tag_sets_id => -1 }, 1 );

    # simple update
    my $update_input = {
        tag_sets_id     => $r->{ tag_set }->{ tag_sets_id },
        name            => 'barz tag',
        label           => 'barz label',
        description     => 'barz description',
        show_on_media   => 0,
        show_on_stories => 0,
    };

    $r = test_put( '/api/v2/tag_sets/update', $update_input );
    validate_db_row( $db, 'tag_sets', $r->{ tag_set }, $update_input, 'update tag set' );

    my $tag_sets       = $db->query( "select * from tag_sets" )->hashes;
    my $got_tag_sets   = test_get( '/api/v2/tag_sets/list' );
    my $tag_set_fields = [ qw/name label description show_on_media show_on_stories/ ];
    rows_match( "tag_sets/list", $got_tag_sets, $tag_sets, 'tag_sets_id', $tag_set_fields );

    my $tag_set = $tag_sets->[ 0 ];
    $got_tag_sets = test_get( '/api/v2/tag_sets/single/' . $tag_set->{ tag_sets_id }, {} );
    rows_match( "tag_sets/single", $got_tag_sets, [ $tag_set ], 'tag_sets_id', $tag_set_fields );

}

# test feeds/list and single
sub test_feeds_list($)
{
    my ( $db ) = @_;

    my $label = "feeds/list";

    my $medium = MediaWords::Test::DB::create_test_medium( $db, $label );

    map { MediaWords::Test::DB::create_test_feed( $db, "$label $_", $medium ) } ( 1 .. 10 );

    my $expected_feeds = $db->query( "select * from feeds where media_id = ?", $medium->{ media_id } )->hashes;

    my $got_feeds = test_get( '/api/v2/feeds/list', { media_id => $medium->{ media_id } } );

    my $fields = [ qw/name url feed_type media_id/ ];
    rows_match( $label, $got_feeds, $expected_feeds, "feeds_id", $fields );

    $label = "feeds/single";

    my $expected_single = $expected_feeds->[ 0 ];

    my $got_feed = test_get( '/api/v2/feeds/single/' . $expected_single->{ feeds_id }, {} );
    rows_match( $label, $got_feed, [ $expected_single ], 'feeds_id', $fields );
}

# test feeds/* end points
sub test_feeds($)
{
    my ( $db ) = @_;

    # test for required fields errors
    test_post( '/api/v2/feeds/create', {}, 1 );
    test_put( '/api/v2/feeds/update', { name => 'foo' }, 1 );

    my $medium = $db->query( "select * from media limit 1" )->hash;

    # simple tag creation
    my $create_input = {
        media_id    => $medium->{ media_id },
        name        => 'feed name',
        url         => 'http://feed.create',
        feed_type   => 'syndicated',
        feed_status => 'active'
    };

    my $r = test_post( '/api/v2/feeds/create', $create_input );
    validate_db_row( $db, 'feeds', $r->{ feed }, $create_input, 'create feed' );

    # error on update non-existent tag
    test_put( '/api/v2/feeds/update', { feeds_id => -1 }, 1 );

    # simple update
    my $update_input = {
        feeds_id    => $r->{ feed }->{ feeds_id },
        name        => 'feed name update',
        url         => 'http://feed.create/update',
        feed_type   => 'web_page',
        feed_status => 'inactive'
    };

    $r = test_put( '/api/v2/feeds/update', $update_input );
    validate_db_row( $db, 'feeds', $r->{ feed }, $update_input, 'update feed' );

    $r = test_post( '/api/v2/feeds/scrape', { media_id => $medium->{ media_id } } );
    ok( $r->{ job_state }, "feeds/scrape job state returned" );
    is( $r->{ job_state }->{ media_id }, $medium->{ media_id }, "feeds/scrape media_id" );
    ok( $r->{ job_state }->{ state } ne 'error', "feeds/scrape job state is not an error" );

    $r = test_get( '/api/v2/feeds/scrape_status', { media_id => $medium->{ media_id } } );
    is( $r->{ job_states }->[ 0 ]->{ media_id }, $medium->{ media_id }, "feeds/scrape_status media_id" );

    $r = test_get( '/api/v2/feeds/scrape_status', {} );
    is( $r->{ job_states }->[ 0 ]->{ media_id }, $medium->{ media_id }, "feeds/scrape_status all media_id" );

    test_feeds_list( $db );
}

# test the media/submit_suggestion call
sub test_media_suggestions_submit($)
{
    my ( $db ) = @_;

    # make sure url is required
    test_post( '/api/v2/media/submit_suggestion', {}, 1 );

    # test with simple url
    my $simple_url = 'http://foo.com';
    test_post( '/api/v2/media/submit_suggestion', { url => $simple_url } );

    my $simple_ms = $db->query( "select * from media_suggestions where url = \$1", $simple_url )->hash;
    ok( $simple_ms, "media/submit_suggestion simple url found" );

    # test with all fields in input
    my $tag_1 = MediaWords::Util::Tags::lookup_or_create_tag( $db, 'media_suggestions:tag_1' );
    my $tag_2 = MediaWords::Util::Tags::lookup_or_create_tag( $db, 'media_suggestions:tag_2' );

    my $full_ms_input = {
        url      => 'http://bar.com',
        name     => 'foo',
        feed_url => 'http://feed.url',
        reason   => 'bar',
        tags_ids => [ map { $_->{ tags_id } } ( $tag_1, $tag_2 ) ]
    };

    test_post( '/api/v2/media/submit_suggestion', $full_ms_input );

    my $full_ms_db = $db->query( "select * from media_suggestions where url = \$1", $full_ms_input->{ url } )->hash;
    ok( $full_ms_db, "media/submit_suggestion full input found" );

    for my $field ( qw/name feed_url reason/ )
    {
        is( $full_ms_db->{ $field }, $full_ms_input->{ $field }, "media/submit_suggestion full input $field" );
    }

    ok( $full_ms_db->{ date_submitted }, "media/submit_suggestion full date_submitted set" );

    for my $tag ( $tag_1, $tag_2 )
    {
        my $tag_exists = $db->query( <<SQL, $tag->{ tags_id }, $full_ms_db->{ media_suggestions_id } )->hash;
select * from media_suggestions_tags_map where tags_id = \$1 and media_suggestions_id = \$2
SQL
        ok( $tag_exists, "media/submit_suggestion full tag $tag->{ tags_id } exists" );
    }
}

# test that the media/list_suggestions call with the given $call_params returned the given results
sub test_suggestions_list_results($$$)
{
    my ( $label, $call_params, $expected_results ) = @_;

    $label = "media/list_suggestions $label";

    my $expected_num = scalar( @{ $expected_results } );

    my $r = test_get( '/api/v2/media/list_suggestions', $call_params );
    my $got_mss = $r->{ media_suggestions };
    ok( $got_mss, "$label media_suggestions set" );

    is( scalar( @{ $got_mss } ), $expected_num, "$label number returned" );

    my $prev_id = 0;
    for my $got_ms ( @{ $got_mss } )
    {
        my ( $expected_ms ) =
          grep { $_->{ media_suggestions_id } == $got_ms->{ media_suggestions_id } } @{ $expected_results };
        ok( $expected_ms, "$label returned ms $got_ms->{ media_suggestions_id } matches db row" );
        for my $field ( qw/status url name feed_url reason media_id mark_reason user/ )
        {
            is( $got_ms->{ $field }, $expected_ms->{ $field }, "$label field $field" );
        }
        ok( $got_ms->{ media_suggestions_id } > $prev_id, "$label media_ids in order" );
        $prev_id = $got_ms->{ media_suggestions_id };
    }

}

# test media/list_suggestions
sub test_media_suggestions_list($)
{
    my ( $db ) = @_;

    my $num_status_ms = 10;

    my ( $auth_users_id, $email ) = $db->query( "select auth_users_id from auth_users limit 1" )->flat;

    my $ms_db     = [];
    my $media_ids = $db->query( "select media_id from media" )->flat;

    my $tag = MediaWords::Util::Tags::lookup_or_create_tag( $db, "media_suggestions:test_tag" );

    for my $status ( qw/pending approved rejected/ )
    {
        for my $i ( 1 .. $num_status_ms )
        {
            my $ms = {
                url           => "http://m.s/$i",
                name          => "ms $i",
                feed_url      => "http://feed.m.s/$i",
                auth_users_id => $auth_users_id,
                reason        => "reason $i",
                status        => $status,
            };

            if ( $status ne 'pending' )
            {
                $ms->{ mark_reason } = "mark reason $i";
                $ms->{ date_marked } = MediaWords::Util::SQL::sql_now;
            }

            if ( $status eq 'approved' )
            {
                $ms->{ media_id } = shift( @{ $media_ids } );
                push( @{ $media_ids }, $ms->{ media_id } );
            }

            $ms = $db->create( 'media_suggestions', $ms );

            $ms->{ email } = $email;

            if ( $i % 2 )
            {
                $ms->{ tags_id } = [ $tag->{ tags_id } ];
                $db->query( <<SQL, $ms->{ media_suggestions_id }, $tag->{ tags_id } );
insert into media_suggestions_tags_map ( media_suggestions_id, tags_id ) values ( \$1, \$2 )
SQL
            }

            push( @{ $ms_db }, $ms );
        }
    }

    test_suggestions_list_results( 'pending', {}, [ grep { $_->{ status } eq 'pending' } @{ $ms_db } ] );
    test_suggestions_list_results( 'all', { all => 1 }, $ms_db );

    my $pending_tags_ms = [ grep { $_->{ status } eq 'pending' && $_->{ tags_id } } @{ $ms_db } ];
    test_suggestions_list_results( 'pending + tags_id', { tags_id => $tag->{ tags_id } }, $pending_tags_ms );

}

# test media/mark_suggestion end point
sub test_media_suggestions_mark($)
{
    my ( $db ) = @_;

    my ( $auth_users_id ) = $db->query( "select auth_users_id from auth_users limit 1" )->flat;

    my $ms = {
        url           => "http://m.s/mark",
        name          => "ms mark",
        feed_url      => "http://feed.m.s/mark",
        auth_users_id => $auth_users_id,
        reason        => "reason mark"
    };
    $ms = $db->create( 'media_suggestions', $ms );
    my $ms_id = $ms->{ media_suggestions_id };

    # test for required status and media_suggestions_id
    test_put( '/api/v2/media/mark_suggestion', {}, 1 );
    test_put( '/api/v2/media/mark_suggestion', { media_suggestions_id => $ms_id }, 1 );
    test_put( '/api/v2/media/mark_suggestion', { status => 'approved' }, 1 );

    # test for error on invalid input
    test_put( '/api/v2/media/mark_suggestion', { media_suggestions_id => 0,      status => 'approved' },       1 );
    test_put( '/api/v2/media/mark_suggestion', { media_suggestions_id => $ms_id, status => 'invalid_status' }, 1 );

    # test reject
    test_put( '/api/v2/media/mark_suggestion',
        { media_suggestions_id => $ms_id, status => 'rejected', mark_reason => 'rejected' } );
    $ms = $db->require_by_id( 'media_suggestions', $ms_id );

    is( $ms->{ status },      'rejected', "media/mark_suggestion reject status" );
    is( $ms->{ mark_reason }, 'rejected', "media/mark_suggestion reject mark_reason" );

    my ( $media_id ) = $db->query( "select media_id from media limit 1" )->flat;

    # test approve
    my $approve_input = {
        media_suggestions_id => $ms_id,
        status               => 'approved',
        mark_reason          => 'approved'
    };

    # verify that approval with media_id causes error
    test_put( '/api/v2/media/mark_suggestion', $approve_input, 1 );

    # now try valid submission
    $approve_input->{ media_id } = $media_id;
    test_put( '/api/v2/media/mark_suggestion', $approve_input );
    $ms = $db->require_by_id( 'media_suggestions', $ms_id );

    is( $ms->{ status },      'approved', "media/mark_suggestion approve status" );
    is( $ms->{ mark_reason }, 'approved', "media/mark_suggestion approve mark_reason" );
    is( $ms->{ media_id },    $media_id,  'media/mark_suggestion approve media_id' );

    # now try setting back to pending
    test_put( '/api/v2/media/mark_suggestion',
        { media_suggestions_id => $ms_id, status => 'pending', mark_reason => 'pending' } );
    $ms = $db->require_by_id( 'media_suggestions', $ms_id );

    is( $ms->{ status },      'pending', "media/mark_suggestion pending status" );
    is( $ms->{ mark_reason }, 'pending', "media/mark_suggestion pending mark_reason" );
}

# test media suggestions list, submit, and mark calls
sub test_media_suggestions($)
{
    my ( $db ) = @_;

    test_media_suggestions_list( $db );
    test_media_suggestions_submit( $db );
    test_media_suggestions_mark( $db );
}

# test topics/ create and update
sub test_topics_crud($)
{
    my ( $db ) = @_;
}

# test wc/list end point
sub test_wc_list($)
{
    my ( $db ) = @_;

    test_get( '/api/v2/wc/list', { q => 'the' } );

    my $label = "wc/list";

    my $story = $db->query( "select * from stories order by stories_id limit 1" )->hash;

    my $sentences = $db->query( <<SQL, $story->{ stories_id } )->flat;
select sentence from story_sentences where stories_id = ?
SQL

    my $en = MediaWords::Languages::Language::language_for_code( 'en' );

    my $expected_word_counts = {};
    for my $sentence ( @{ $sentences } )
    {
        my $words = [ grep { length( $_ ) > 2 } split( /\W+/, lc( $sentence ) ) ];
        my $stems = $en->stem( @{ $words } );
        map { $expected_word_counts->{ $_ }++ } @{ $stems };
    }

    my $got_word_counts = test_get(
        '/api/v2/wc/list',
        {
            q                 => "stories_id:$story->{ stories_id }",
            languages         => 'en',                                 # set to english so that we can know how to stem above
            num_words         => 10000,
            include_stopwords => 1                                     # don't try to test stopwording
        }
    );

    is( scalar( @{ $got_word_counts } ), scalar( keys( %{ $expected_word_counts } ) ), "$label number of words" );

    for my $got_word_count ( @{ $got_word_counts } )
    {
        my $stem = $got_word_count->{ stem };
        ok( $expected_word_counts->{ $stem }, "$label word count for '$stem' is found but not expected" );
        is( $got_word_count->{ count }, $expected_word_counts->{ $stem }, "$label expected word count for '$stem'" );
    }
}

# test controversies/list and single
sub test_controversies($)
{
    my ( $db ) = @_;

    my $label = "controversies/list";

    map { MediaWords::Test::DB::create_test_topic( $db, "$label $_" ) } ( 1 .. 10 );

    my $expected_topics = $db->query( "select *, topics_id controversies_id from topics" )->hashes;

    my $got_controversies = test_get( '/api/v2/controversies/list', {} );

    my $fields = [ qw/controversies_id name pattern solr_seed_query description max_iterations/ ];
    rows_match( $label, $got_controversies, $expected_topics, "controversies_id", $fields );

    $label = "controversies/single";

    my $expected_single = $expected_topics->[ 0 ];

    my $got_controversy = test_get( '/api/v2/controversies/single/' . $expected_single->{ topics_id }, {} );
    rows_match( $label, $got_controversy, [ $expected_single ], 'controversies_id', $fields );
}

# test controversy_dumps/list and single
sub test_controversy_dumps($)
{
    my ( $db ) = @_;

    my $label = "controversy_dumps/list";

    my $topic = MediaWords::Test::DB::create_test_topic( $db, $label );

    for my $i ( 1 .. 10 )
    {
        $db->create(
            'snapshots',
            {
                topics_id     => $topic->{ topics_id },
                snapshot_date => '2017-01-01',
                start_date    => '2016-01-01',
                end_date      => '2017-01-01',
                note          => "snapshot $i"
            }
        );
    }

    my $expected_snapshots = $db->query( <<SQL, $topic->{ topics_id } )->hashes;
select *, topics_id controversies_id, snapshots_id controversy_dumps_id
    from snapshots
    where topics_id = ?
SQL

    my $got_cds = test_get( '/api/v2/controversy_dumps/list', { controversies_id => $topic->{ topics_id } } );

    my $fields = [ qw/controversies_id controversy_dumps_id start_date end_date note/ ];
    rows_match( $label, $got_cds, $expected_snapshots, 'controversy_dumps_id', $fields );

    $label = 'controversy_dumps/single';

    my $expected_snapshot = $expected_snapshots->[ 0 ];

    my $got_cd = test_get( '/api/v2/controversy_dumps/single/' . $expected_snapshot->{ snapshots_id }, {} );
    rows_match( $label, $got_cd, [ $expected_snapshot ], 'controversy_dumps_id', $fields );
}

# test controversy_dump_time_slices/list and single
sub test_controversy_dump_time_slices($)
{
    my ( $db ) = @_;

    my $label = "controversy_dump_time_slices/list";

    my $topic = MediaWords::Test::DB::create_test_topic( $db, $label );
    my $snapshot = $db->create(
        'snapshots',
        {
            topics_id     => $topic->{ topics_id },
            snapshot_date => '2017-01-01',
            start_date    => '2016-01-01',
            end_date      => '2017-01-01',
        }
    );

    my $metrics = [
        qw/story_count story_link_count medium_count medium_link_count tweet_count /,
        qw/model_num_media model_r2_mean model_r2_stddev/
    ];
    for my $i ( 1 .. 9 )
    {
        my $timespan = {
            snapshots_id => $snapshot->{ snapshots_id },
            start_date   => '2016-01-0' . $i,
            end_date     => '2017-01-0' . $i,
            period       => 'custom'
        };

        map { $timespan->{ $_ } = $i * length( $_ ) } @{ $metrics };
        $db->create( 'timespans', $timespan );
    }

    my $expected_timespans = $db->query( <<SQL, $snapshot->{ snapshots_id } )->hashes;
select *, snapshots_id controversy_dumps_id, timespans_id controversy_dump_time_slices_id
    from timespans
    where snapshots_id = ?
SQL

    my $got_cdtss =
      test_get( '/api/v2/controversy_dump_time_slices/list', { controversy_dumps_id => $snapshot->{ snapshots_id } } );

    my $fields = [ qw/controversy_dumps_id start_date end_date period/, @{ $metrics } ];
    rows_match( $label, $got_cdtss, $expected_timespans, 'controversy_dump_time_slices_id', $fields );

    $label = 'controversy_dump_time_slices/single';

    my $expected_timespan = $expected_timespans->[ 0 ];

    my $got_cdts = test_get( '/api/v2/controversy_dump_time_slices/single/' . $expected_timespan->{ timespans_id }, {} );
    rows_match( $label, $got_cdts, [ $expected_timespan ], 'controversy_dump_time_slices_id', $fields );
}

# test downloads/list and single
sub test_downloads($)
{
    my ( $db ) = @_;

    my $label = "downloads/list";

    my $medium = MediaWords::Test::DB::create_test_medium( $db, $label );
    my $feed = MediaWords::Test::DB::create_test_feed( $db, $label, $medium );
    for my $i ( 1 .. 10 )
    {
        my $download = $db->create(
            'downloads',
            {
                feeds_id => $feed->{ feeds_id },
                url      => 'http://test.download/' . $i,
                host     => 'test.download',
                type     => 'feed',
                state    => 'success',
                path     => $i + $i,
                priority => $i,
                sequence => $i * $i
            }
        );

        my $content = "content $download->{ downloads_id }";
        MediaWords::DBI::Downloads::store_content( $db, $download, \$content );
    }

    my $expected_downloads = $db->query( "select * from downloads where feeds_id = ?", $feed->{ feeds_id } )->hashes;
    map { $_->{ raw_content } = "content $_->{ downloads_id }" } @{ $expected_downloads };

    my $got_downloads = test_get( '/api/v2/downloads/list', { feeds_id => $feed->{ feeds_id } } );

    my $fields = [ qw/feeds_id url guid type state priority sequence download_time host/ ];
    rows_match( $label, $got_downloads, $expected_downloads, "downloads_id", $fields );

    $label = "downloads/single";

    my $expected_single = $expected_downloads->[ 0 ];

    my $got_download = test_get( '/api/v2/downloads/single/' . $expected_single->{ downloads_id }, {} );
    rows_match( $label, $got_download, [ $expected_single ], 'downloads_id', $fields );

}

# test mediahealth/list and single
sub test_mediahealth($)
{
    my ( $db ) = @_;

    my $label = "mediahealth/list";

    my $metrics = [
        qw/num_stories num_stories_w num_stories_90 num_stories_y num_sentences num_sentences_w/,
        qw/num_sentences_90 num_sentences_y expected_stories expected_sentences coverage_gaps/
    ];
    for my $i ( 1 .. 10 )
    {
        my $medium = MediaWords::Test::DB::create_test_medium( $db, "$label $i" );
        my $mh = {
            media_id        => $medium->{ media_id },
            is_healthy      => ( $medium->{ media_id } % 2 ) ? 't' : 'f',
            has_active_feed => ( $medium->{ media_id } % 2 ) ? 't' : 'f',
            start_date      => '2011-01-01',
            end_date        => '2017-01-01'
        };

        map { $mh->{ $_ } = $i * length( $_ ) } @{ $metrics };

        $db->create( 'media_health', $mh );
    }

    my $expected_mhs = $db->query( <<SQL, $label )->hashes;
select mh.* from media_health mh join media m using ( media_id ) where m.name like ? || '%'
SQL

    my $media_id_params = join( '&', map { "media_id=$_->{ media_id }" } @{ $expected_mhs } );

    my $got_mhs = test_get( '/api/v2/mediahealth/list?' . $media_id_params, {} );

    my $fields = [ qw/media_id is_health has_active_feed start_date end_date/, @{ $metrics } ];
    rows_match( $label, $got_mhs, $expected_mhs, 'media_id', $fields );
}

sub test_sentences_count($)
{
    my ( $db ) = @_;

    my $label = "setences/count";

    my $stories     = $db->query( "select * from stories order by stories_id asc limit 10" )->hashes;
    my $stories_ids = [ map { $_->{ stories_id } } @{ $stories } ];
    my $ss          = $db->query( 'select * from story_sentences where stories_id in ( ?? )', @{ $stories_ids } )->hashes;

    my $stories_ids_list = join( ' ', @{ $stories_ids } );
    my $r = test_get( '/api/v2/sentences/count', { q => "stories_id:($stories_ids_list)" } );

    # we import titles as sentences as well as the sentences themselves, so expect them in the count
    my $expected_count = scalar( @{ $ss } ) + 10;

    is( $r->{ count }, $expected_count, "$label count" );
}

sub test_sentences_field_count($)
{
    my ( $db ) = @_;

    my $label = "setences/field_count";

    my $tag = MediaWords::Util::Tags::lookup_or_create_tag( $db, "$label:$label" );

    my $stories = $db->query( "select * from stories order by stories_id asc limit 10" )->hashes;
    my $tagged_stories = [ ( @{ $stories } )[ 1 .. 5 ] ];
    for my $story ( @{ $tagged_stories } )
    {
        $db->query( <<SQL, $story->{ stories_id }, $tag->{ tags_id } );
insert into stories_tags_map ( stories_id, tags_id ) values ( ?, ? )
SQL
    }

    my $stories_ids = [ map { $_->{ stories_id } } @{ $stories } ];
    my $stories_ids_list = join( ' ', @{ $stories_ids } );

    my $tagged_stories_ids = [ map { $_->{ stories_id } } @{ $tagged_stories } ];

    my $r = test_get( '/api/v2/sentences/field_count',
        { field => 'tags_id_stories', q => "stories_id:($stories_ids_list)", tag_sets_id => $tag->{ tag_sets_id } } );

    is( scalar( @{ $r } ), 1, "$label num of tags" );

    my $got_tag = $r->[ 0 ];
    is( $got_tag->{ count }, scalar( @{ $tagged_stories } ), "$label count" );
    map { is( $got_tag->{ $_ }, $tag->{ $_ }, "$label field '$_'" ) } ( qw/tag tags_id label tag_sets_id/ );
}

sub test_sentences_list($)
{
    my ( $db ) = @_;

    my $label = "setences/list";

    my $stories     = $db->query( "select * from stories order by stories_id asc limit 10" )->hashes;
    my $stories_ids = [ map { $_->{ stories_id } } @{ $stories } ];
    my $ss          = $db->query( 'select * from story_sentences where stories_id in ( ?? )', @{ $stories_ids } )->hashes;

    my $stories_ids_list = join( ' ', @{ $stories_ids } );
    my $r = test_get( '/api/v2/sentences/list', { q => "stories_id:($stories_ids_list) and sentence:[* TO *]" } );

    is( $r->{ response }->{ numFound }, scalar( @{ $ss } ), "$label num found" );

    my $fields = [ qw/stories_id media_id sentence/ ];
    rows_match( $label, $r->{ response }->{ docs }, $ss, 'story_sentences_id', $fields );
}

sub test_sentences($)
{
    my ( $db ) = @_;

    test_sentences_count( $db );
    test_sentences_field_count( $db );
    test_sentences_list( $db );
}

sub test_stats_list($)
{
    my ( $db ) = @_;

    my $label = "stats/list";

    MediaWords::DBI::Stats::refresh_stats( $db );

    my $ms = $db->query( "select * from mediacloud_stats" )->hash;

    my $r = test_get( '/api/v2/stats/list', {} );

    my $fields = [
        qw/stats_date daily_downloads daily_stories active_crawled_media active_crawled_feeds/,
        qw/total_stories total_downloads total_sentences/
    ];

    map { is( $r->{ $_ }, $ms->{ $_ }, "$label field '$_'" ) } @{ $fields };
}

sub test_stories_corenlp($)
{
    my ( $db ) = @_;

    # TODO add infrastructure to actually generate corenlp and test it

    my $label = "stories/corenlp";

    # pick a stories_id that does not exist so that we make the end point just tell us that the
    # end point does not exist instead of triggering a fatal error
    my $stories_id = -1;

    my $r = test_get( '/api/v2/stories/corenlp', { stories_id => $stories_id } );

    is( scalar( @{ $r } ),         1,                      "$label num stories returned" );
    is( $r->[ 0 ]->{ stories_id }, $stories_id,            "$label stories_id" );
    is( $r->[ 0 ]->{ corenlp },    "story does not exist", "$label does not exist message" );
}

sub test_stories_fetch_bitly_clicks($)
{
    my ( $db ) = @_;

    # TODO add infrastructure to be able to test direct fetch from bitly

    # barring ability to test bitly fetch, just request a non-existent stories_id
    my $stories_id = -1;

    my $params = { stories_id => $stories_id, start_timestamp => '2016-01-01', end_timestamp => '2017-01-01' };
    my $r = test_get( '/api/v2/stories/fetch_bitly_clicks', $params, 1 );

    is( $r->{ error }, "stories_id '-1' does not exist" );
}

sub test_stories_list($)
{
    my ( $db ) = @_;

    my $label = "stories/list";

    my $stories = $db->query( <<SQL )->hashes;
select s.*,
        m.name media_name,
        m.url media_url,
        false ap_syndicated
    from stories s
        join media m using ( media_id )
    order by stories_id
    limit 10
SQL

    my $stories_ids_list = join( ' ', map { $_->{ stories_id } } @{ $stories } );

    my $params = {
        q                => "stories_id:( $stories_ids_list )",
        raw_1st_download => 1,
        sentences        => 1,
        text             => 1,
        corenlp          => 0
    };

    my $got_stories = test_get( '/api/v2/stories/list', $params );

    my $fields = [ qw/title description publish_date language collect_date ap_syndicated media_id media_name media_url/ ];
    rows_match( $label, $got_stories, $stories, 'stories_id', $fields );

    my $got_stories_lookup = {};
    map { $got_stories_lookup->{ $_->{ stories_id } } = $_ } @{ $got_stories };

    for my $story ( @{ $stories } )
    {
        my $sid       = $story->{ stories_id };
        my $got_story = $got_stories_lookup->{ $story->{ stories_id } };

        my $sentences = $db->query( "select * from story_sentences where stories_id = ?", $sid )->hashes;
        my $download_text = $db->query( <<SQL, $sid )->hash;
select dt.*
    from download_texts dt
        join downloads d using ( downloads_id )
    where d.stories_id = ?
    order by dt.download_texts_id
    limit 1
SQL
        my $content_ref = MediaWords::DBI::Stories::get_content_for_first_download( $db, $story );

        my $ss_fields = [ qw/is_dup language media_id publish_date sentence sentence_number story_sentences_id/ ];
        rows_match( "$label $sid sentences", $got_story->{ story_sentences }, $sentences, 'story_sentences_id', $ss_fields );

        is( $got_story->{ raw_first_download_file }, $$content_ref, "$label $sid download" );
        is( $got_story->{ story_text }, $download_text->{ download_text }, "$label $sid download_text" );
    }

    my $story = $stories->[ 0 ];

    my $got_story = test_get( '/api/v2/stories/single/' . $story->{ stories_id }, {} );
    rows_match( "stories/single", $got_story, [ $story ], 'stories_id', [ qw/stories_id title publish_date/ ] );

}

sub test_stories_single($)
{
    my ( $db ) = @_;

    my $label = "stories/list";

    my $story = $db->query( <<SQL )->hash;
select s.*,
        m.name media_name,
        m.url media_url,
        false ap_syndicated
    from stories s
        join media m using ( media_id )
    order by stories_id
    limit 1
SQL

    my $got_stories = test_get( '/api/v2/stories/list', { q => "stories_id:$story->{ stories_id }" } );

    my $fields = [ qw/title description publish_date language collect_date ap_syndicated media_id media_name media_url/ ];
    rows_match( $label, $got_stories, [ $story ], 'stories_id', $fields );
}

sub test_stories_word_matrix($)
{
    my ( $db ) = @_;

    my $label = "stories/word_matrix";

    my $stories          = $db->query( "select * from stories order by stories_id limit 17" )->hashes;
    my $stories_ids      = [ map { $_->{ stories_id } } @{ $stories } ];
    my $stories_ids_list = join( ' ', @{ $stories_ids } );

    # this functionality is already tested in test_get_story_word_matrix(), so we're just makingn sure no errors
    # are generated and the return format is correct

    my $r = test_get( '/api/v2/stories/word_matrix', { q => "stories_id:( $stories_ids_list )" } );
    ok( $r->{ word_matrix }, "$label word matrix present" );
    ok( $r->{ word_list },   "$label word list present" );

    $r = test_get( '/api/v2/stories_public/word_matrix', { q => "stories_id:( $stories_ids_list )" } );
    ok( $r->{ word_matrix }, "$label word matrix present" );
    ok( $r->{ word_list },   "$label word list present" );

}

sub test_stories($$)
{
    my ( $db, $media ) = @_;

    test_stories_corenlp( $db );
    test_stories_fetch_bitly_clicks( $db );
    test_stories_list( $db );
    test_stories_single( $db );
    test_stories_public_list( $db, $media );
    test_stories_count( $db );
    test_stories_word_matrix( $db );
}

# test whether we have at least requested every api end point outside of topics/
sub test_coverage()
{
    my $untested_urls = MediaWords::Test::API::get_untested_api_urls();

    $untested_urls = [ grep { $_ !~ m~/topics/~ } @{ $untested_urls } ];

    ok( scalar( @{ $untested_urls } ) == 0, "end points not requested: " . join( ', ', @{ $untested_urls } ) );
}

# test parts of the ai that only require reading, so we can test these all in one chunk
sub test_api($)
{
    my ( $db ) = @_;

    my $media = MediaWords::Test::DB::create_test_story_stack_numerated( $db, $NUM_MEDIA, $NUM_FEEDS_PER_MEDIUM,
        $NUM_STORIES_PER_FEED );

    MediaWords::Test::DB::add_content_to_test_story_stack( $db, $media );

    MediaWords::Test::Solr::setup_test_index( $db );

    MediaWords::Test::API::setup_test_api_key( $db );

    test_stories( $db, $media );

    test_auth( $db );
    test_media( $db, $media );
    test_tag_sets( $db );
    test_feeds( $db );

    test_tags( $db );
    test_media_suggestions( $db );

    test_topics_crud( $db );

    test_controversies( $db );
    test_controversy_dumps( $db );
    test_controversy_dump_time_slices( $db );

    test_downloads( $db );
    test_mediahealth( $db );

    test_wc_list( $db );

    test_sentences( $db );

    test_stats_list( $db );

    test_coverage();
}

sub main
{
    MediaWords::Test::Supervisor::test_with_supervisor( \&test_api,
        [ 'solr_standalone', 'job_broker:rabbitmq', 'rescrape_media' ] );

    done_testing();
}

main();
