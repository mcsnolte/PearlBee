package PearlBee;

# ABSTRACT: PearlBee Blog platform

use Dancer2;
use Dancer2::Plugin::DBIC;

# Other used modules
use Authen::Captcha;
use Digest::MD5 qw(md5_hex);
use Gravatar::URL;
use DateTime;

# Included controllers

# Common controllers
use PearlBee::Authentication;
use PearlBee::Authorization;
use PearlBee::Dashboard;

# Admin controllers
use PearlBee::Admin::Category;
use PearlBee::Admin::Tag;
use PearlBee::Admin::Post;
use PearlBee::Admin::Comment;
use PearlBee::Admin::User;
use PearlBee::Admin::Settings;

# Author controllers
use PearlBee::Author::Post;
use PearlBee::Author::Comment;

use PearlBee::Helpers::Util qw(generate_crypted_filename);
our $VERSION = '0.1';

=head

Prepare the blog path

=cut

hook 'before' => sub {

  session app_url => config->{app_url} unless ( session('app_url') );

};

=head

Home page

=cut

get '/' => sub {
  
  my $nr_of_rows  = 6; # Number of posts per page
  my @posts       = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => $nr_of_rows });
  my $nr_of_posts = resultset('Post')->search({ status => 'published' })->count;
  my @tags        = resultset('View::PublishedTags')->all();
  my @categories  = resultset('View::PublishedCategories')->search({ name => { '!=' => 'Uncategorized'} });
  my @recent      = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => 3 });
  my @popular     = resultset('View::PopularPosts')->search({}, { rows => 3 });

  my $total_pages = ( ($nr_of_posts / $nr_of_rows) != int($nr_of_posts / $nr_of_rows) ) ? int($nr_of_posts / $nr_of_rows) + 1 : ($nr_of_posts % $nr_of_rows);
  my $previous_link = '#';
  my $next_link     =  ( $total_pages < 2 ) ? '#' : '/page/2';
  my $posts2     = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => $nr_of_rows })->first;


    template 'index', 
      { 
        posts         => \@posts,
        recent        => \@recent,
        popular       => \@popular,
        tags          => \@tags,
        categories    => \@categories,
        page          => 1,
        total_pages   => $total_pages,
        previous_link => $previous_link,
        next_link     => $next_link
    }, 
    { layout => 'main' };
};

=head

Home page

=cut

get '/page/:page' => sub {

  my $nr_of_rows  = 6; # Number of posts per page
  my $page        = params->{page};
  my @posts       = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => $nr_of_rows, page => $page });
  my $nr_of_posts = resultset('Post')->search({ status => 'published' })->count;
  my @tags        = resultset('View::PublishedTags')->all();
  my @categories  = resultset('View::PublishedCategories')->search({ name => { '!=' => 'Uncategorized'} });
  my @recent      = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => 3 });
  my @popular     = resultset('View::PopularPosts')->search({}, { rows => 3 });

  my $total_pages   = ( ($nr_of_posts / $nr_of_rows) != int($nr_of_posts / $nr_of_rows) ) ? int($nr_of_posts / $nr_of_rows) + 1 : ($nr_of_posts % $nr_of_rows);

  # Calculate the next and previous page link
  my $previous_link   = ( $page == 1 ) ? '#' : '/page/' . ( int($page) - 1 );
  my $next_link     = ( $page == $total_pages ) ? '#' : '/page/' . ( int($page) + 1 );

    template 'index', 
      { 
        posts         => \@posts,
        recent        => \@recent,
        popular       => \@popular,
        tags          => \@tags,
        categories    => \@categories,
        page          => $page,
        total_pages   => $total_pages,
        previous_link => $previous_link,
        next_link     => $next_link
    }, 
    { layout => 'main' };
};


=head

View post method

=cut

get '/post/:slug' => sub {
  
  my $slug       = params->{slug};
  my $post       = resultset('Post')->find({ slug => $slug });
  my $settings   = resultset('Setting')->first;
  my @categories = resultset('View::PublishedCategories')->search({ name => { '!=' => 'Uncategorized'} });

  my $captcha    = Authen::Captcha->new();

  # set the data_folder. contains flatfile db to maintain state
  $captcha->data_folder('public/captcha');

  # set directory to hold publicly accessable images
  $captcha->output_folder('public/captcha/image');
  my $md5sum = $captcha->generate_code(5);

  # Rename the image file so that the encrypted code won't show on the UI
  my $command = "mv " . config->{captcha_folder} . "/image/" . $md5sum . ".png" . " " . config->{captcha_folder} . "/image/image.png";
  `$command`;

  # Store the encrypted code on the session
  session secret => $md5sum;

  # Grab the approved comments for this post
  my @comments;
  @comments = resultset('Comment')->search({ post_id => $post->id, status => 'approved' }) if ( $post );

  template 'post', 
    { 
      post        => $post, 
      categories  => \@categories, 
      comments    => \@comments,
      setting    => $settings
    }, 
    { layout => 'main' };
};

=head 

Add a comment method

=cut

post '/comment/add' => sub {

  # Set the proper timezone
  my $dt       = DateTime->now;          
  my $settings = resultset('Setting')->first;
  $dt->set_time_zone( $settings->timezone );

  my $fullname = params->{fullname};
  my $email    = params->{email};
  my $website  = params->{website} || '';
  my $text     = params->{comment};
  my $post_id  = params->{id};
  my $secret   = params->{secret};

  my $post     = resultset('Post')->find( $post_id );
  my @categories   = resultset('Category')->all();

  # Grap the approved comments for this post
  my @comments = resultset('Comment')->search({ post_id => $post_id, status => 'approved' });

  # Grab the gravatar if exists, or a default image if not
  my $gravatar = gravatar_url(email => $email);

  if ( md5_hex($secret) eq session('secret') ) {
    # The user entered the correct secrete code
    eval {
      my $comment = resultset('Comment')->create({
          fullname     => $fullname,
          content      => $text,
          email        => $email,
          website      => $website,
          avatar       => $gravatar,
          post_id      => $post_id,
          comment_date => join ' ', $dt->ymd, $dt->hms
        });

      # Notify the author that a new comment was submited
      my $author = $post->user;
      Email::Template->send( config->{email_templates} . 'new_comment.tt',
      {
          From    => 'no-reply@PearlBee.com',
          To      => $author->email,
          Subject => 'A new comment was submited to your post',

          tt_vars => { 
              fullname => $fullname,
              title    => $post->title,
              post_url => config->{app_url} . '/post/' . $post->id,
              url      => config->{app_url}
          },
      }) or error "Could not send the email";
    };

    error $@ if ( $@ );
    
    template 'post', 
      { 
        post        => $post, 
        categories  => \@categories, 
        comments    => \@comments,       
        success     => 'Your comment has been submited and it will be displayed as soon as the author accepts it. Thank you!'
      }, 
      { layout => 'main' };
  }
  else {
    # The secret code inncorrect
    # Repopulate the fields with the data

    # Generate a new captcha code
    my $captcha = Authen::Captcha->new();

    # set the data_folder. contains flatfile db to maintain state
    $captcha->data_folder('public/captcha');

    # set directory to hold publicly accessable images
    $captcha->output_folder('public/captcha/image');
    my $md5sum = $captcha->generate_code(5);

    # Rename the file so that the encrypted code won't show on the UI
    my $command = "mv public/captcha/image/" . $md5sum . ".png" . " public/captcha/image/image.png";
    `$command`;

    # Store the encrypted code on the session
    session secret => $md5sum;

    template 'post', 
      { 
        post        => $post, 
        categories  => \@categories, 
        comments    => \@comments,
        fullname    => $fullname,
        email       => $email,
        website     => $website,
        text        => $text,
        warning     => 'Wrong secret code. Please enter the code again'
      }, 
      { layout => 'main' };
  }  
  
};

=head

List all posts by selected category

=cut

get '/posts/category/:slug' => sub {

  my $nr_of_rows  = 5; # Number of posts per page
  my $slug        = params->{slug};
  my @posts       = resultset('Post')->search({ 'category.slug' => $slug, 'status' => 'published' }, { join => { 'post_categories' => 'category' }, rows => $nr_of_rows });
  my $nr_of_posts = resultset('Post')->search({ 'category.slug' => $slug }, { join => { 'post_categories' => 'category' } })->count;
  my @tags        = resultset('View::PublishedTags')->all();
  my @categories  = resultset('View::PublishedCategories')->search({ name => { '!=' => 'Uncategorized'} });
  my @recent      = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => 3 });
  my @popular     = resultset('View::PopularPosts')->search({}, { rows => 3 });

  my $total_pages   = ( ($nr_of_posts / $nr_of_rows) != int($nr_of_posts / $nr_of_rows) ) ? int($nr_of_posts / $nr_of_rows) + 1 : ($nr_of_posts % $nr_of_rows);
  my $previous_link = '#';
  my $next_link     = ( $total_pages < 2 ) ? '#' : '/posts/category/' . $slug . '/page/2';

  # Extract all posts with the wanted category
  template 'index', 
      { 
        posts         => \@posts,
        recent        => \@recent,
        popular       => \@popular,
        tags          => \@tags,
        page          => 1,
        categories    => \@categories,
        total_pages   => $total_pages,
        next_link     => $next_link,
        previous_link => $previous_link
    }, 
    { layout => 'main' };
};

=head

List all posts by selected category

=cut

get '/posts/category/:slug/page/:page' => sub {

  my $nr_of_rows  = 5; # Number of posts per page
  my $page        = params->{page};
  my $slug        = params->{slug};
  my @posts       = resultset('Post')->search({ 'category.slug' => $slug, 'status' => 'published' }, { join => { 'post_categories' => 'category' }, rows => $nr_of_rows, page => $page });
  my $nr_of_posts = resultset('Post')->search({ 'category.slug' => $slug }, { join => { 'post_categories' => 'category' } })->count;
  my @tags        = resultset('View::PublishedTags')->all();
  my @categories  = resultset('View::PublishedCategories')->search({ name => { '!=' => 'Uncategorized'} });
  my @recent      = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => 3 });
  my @popular     = resultset('View::PopularPosts')->search({}, { rows => 3 });

  my $total_pages   = ( ($nr_of_posts / $nr_of_rows) != int($nr_of_posts / $nr_of_rows) ) ? int($nr_of_posts / $nr_of_rows) + 1 : ($nr_of_posts % $nr_of_rows);

  # Calculate the next and previous page link
  my $previous_link   = ( $page == 1 ) ? '#' : '/posts/category/' . $slug . '/page/' . ( int($page) - 1 );
  my $next_link     = ( $page == $total_pages ) ? '#' : '/posts/category/' . $slug . '/page/' . ( int($page) + 1 );

  template 'index', 
      { 
        posts         => \@posts,
        recent        => \@recent,
        popular       => \@popular,
        tags          => \@tags,
        categories    => \@categories,
        page          => $page,
        total_pages   => $total_pages,
        next_link     => $next_link,
        previous_link => $previous_link
    }, 
    { layout => 'main' };
};

=head

List all posts by selected tag

=cut

get '/posts/tag/:slug' => sub {

  my $nr_of_rows  = 5; # Number of posts per page
  my $slug        = params->{slug};
  my @posts       = resultset('Post')->search({ 'tag.slug' => $slug, 'status' => 'published' }, { join => { 'post_tags' => 'tag' }, rows => $nr_of_rows });
  my $nr_of_posts = resultset('Post')->search({ 'tag.slug' => $slug }, { join => { 'post_tags' => 'tag' } })->count;
  my @tags        = resultset('View::PublishedTags')->all();
  my @categories  = resultset('View::PublishedCategories')->search({ name => { '!=' => 'Uncategorized'} });
  my @recent      = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => 3 });
  my @popular     = resultset('View::PopularPosts')->search({}, { rows => 3 });

  my $total_pages = ( ($nr_of_posts / $nr_of_rows) != int($nr_of_posts / $nr_of_rows) ) ? int($nr_of_posts / $nr_of_rows) + 1 : ($nr_of_posts % $nr_of_rows);
  my $previous_link = '#';
  my $next_link     = ( $total_pages < 2 ) ? '#' : '/posts/tag/' . $slug . '/page/2';

  template 'index', 
      {         
        posts         => \@posts,
        recent        => \@recent,
        popular       => \@popular,
        tags          => \@tags,
        page          => 1,
        categories    => \@categories,
        total_pages   => $total_pages,
        next_link     => $next_link,
        previous_link => $previous_link
    }, 
    { layout => 'main' };
};

=head

List all posts by selected tag

=cut

get '/posts/tag/:slug/page/:page' => sub {

  my $nr_of_rows  = 5; # Number of posts per page
  my $page        = params->{page};
  my $slug        = params->{slug};
  my $tag         = resultset('Tag')->find({ slug => $slug });
  my @posts       = resultset('Post')->search({ 'tag.slug' => $slug, 'status' => 'published' }, { join => { 'post_tags' => 'tag' }, rows => $nr_of_rows });
  my $nr_of_posts = resultset('Post')->search({ 'tag.slug' => $slug }, { join => { 'post_tags' => 'tag' } })->count;
  my @tags        = resultset('View::PublishedTags')->all();
  my @categories  = resultset('View::PublishedCategories')->search({ name => { '!=' => 'Uncategorized'} });
  my @recent      = resultset('Post')->search({ status => 'published' },{ order_by => "created_date DESC", rows => 3 });
  my @popular     = resultset('View::PopularPosts')->search({}, { rows => 3 });

  my $total_pages   = ( ($nr_of_posts / $nr_of_rows) != int($nr_of_posts / $nr_of_rows) ) ? int($nr_of_posts / $nr_of_rows) + 1 : ($nr_of_posts % $nr_of_rows);

  # Calculate the next and previous page link
  my $previous_link = ( $page == 1 ) ? '#' : '/posts/tag/' . $slug . '/page/' . ( int($page) - 1 );
  my $next_link     = ( $page == $total_pages ) ? '#' : '/posts/tag/' . $slug . '/page/' . ( int($page) + 1 );

  template 'index', 
      { 
        posts         => \@posts,
        recent        => \@recent,
        popular       => \@popular,
        tags          => \@tags,
        page          => $page,
        categories    => \@categories,
        total_pages   => $total_pages,
        next_link     => $next_link,
        previous_link => $previous_link
    }, 
    { layout => 'main' };
};

true;
