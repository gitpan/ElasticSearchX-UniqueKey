package ElasticSearchX::UniqueKey;
$ElasticSearchX::UniqueKey::VERSION = '0.05';
use strict;
use warnings;
use Carp;

#===================================
sub new {
#===================================
    my $class  = shift;
    my %params = (
        index => 'unique_key',
        ref $_[0] ? %{ shift() } : @_
    );
    my $self = bless {}, $class;
    for (qw(index es)) {
        $self->{"_$_"} = $params{$_}
            or croak "Missing required param $_";
    }
    return $self;
}

#===================================
sub create {
#===================================
    my $self = shift;
    my %params = $self->_params( 'create', @_ );

    eval {
        $self->es->create( %params, data => {} );
        1;
    }
        && return 1;
    return 0
        if $@->isa('Search::Elasticsearch::Error::Conflict')
        || $@->isa('ElasticSearch::Error::Conflict');
    croak $@;
}

#===================================
sub delete {
#===================================
    my $self = shift;
    my %params = $self->_params( 'delete', @_ );
    $self->es->delete( %params, ignore_missing => 1 );
}

#===================================
sub exists {
#===================================
    my $self = shift;
    my %params = $self->_params( 'exists', @_ );
    $self->es->exists(%params);
}

#===================================
sub update {
#===================================
    my $self   = shift;
    my %params = $self->_params( 'update', shift(), shift() );
    my $new_id = shift();
    croak "No new id passed to update()"
        unless defined $new_id and length $new_id;

    my ( $type, $old_id ) = @params{ 'type', 'id' };
    return 1 if $new_id eq $old_id;
    return unless $self->create( $type, $new_id );
    $self->delete( $type, $old_id );
    1;

}

#===================================
sub multi_create {
#===================================
    my ( $self, %keys ) = @_;

    my @docs = map { { type => $_, id => $keys{$_}, data => {} } } keys %keys;

    my %failed;
    $self->es->bulk_create(
        index       => $self->index,
        docs        => \@docs,
        on_conflict => sub {
            my ( $action, $doc ) = @_;
            $failed{ $doc->{type} } = $doc->{id};
        },
        on_error => sub {
            die "Error creating multi unique keys: $_[2]";
        }
    );
    if (%failed) {
        delete @keys{ keys %failed };
        $self->multi_delete(%keys);
    }
    return %failed;
}

#===================================
sub multi_delete {
#===================================
    my ( $self, %keys ) = @_;

    my @docs = map { { type => $_, id => $keys{$_} } } keys %keys;

    $self->es->bulk_delete(
        index    => $self->index,
        docs     => \@docs,
        on_error => sub {
            die "Error deleting multi unique keys: $_[2]";
        }
    );
    return 1;
}

#===================================
sub multi_update {
#===================================
    my $self = shift;
    my %old  = %{ shift() || {} };
    my %new  = %{ shift() || {} };
    for ( keys %new ) {
        no warnings 'uninitialized';
        next unless $old{$_} eq $new{$_};
        delete $old{$_};
        delete $new{$_};
    }
    my %failed = $self->multi_create(%new);
    $self->multi_delete(%old) unless %failed;
    return %failed;
}

#===================================
sub multi_exists {
#===================================
    my ( $self, %keys ) = @_;
    my @docs = map { { _type => $_, _id => $keys{$_} } } keys %keys;
    my $exists = $self->es->mget( index => $self->index, docs => \@docs );
    for (@$exists) {
        next unless $_->{exists};
        delete $keys{ $_->{_type} };
    }
    return %keys;
}

#===================================
sub _params {
#===================================
    my ( $self, $method, $type, $id ) = @_;
    croak "No type passed to ${method}()"
        unless defined $type and length $type;
    croak "No id passed to ${method}()"
        unless defined $id and length $id;

    return (
        index => $self->index,
        type  => $type,
        id    => $id
    );
}

#===================================
sub bootstrap {
#===================================
    my $self = shift;
    my %params = ref $_[0] eq 'HASH' ? %{ shift() } : @_;
    %params = (
        auto_expand_replicas => '0-all',
        number_of_shards     => 1,
    ) unless %params;

    my $es    = $self->es;
    my $index = $self->index;
    return if $es->index_exists( index => $index );

    $es->create_index(
        index    => $index,
        settings => \%params,
        mappings => {
            _default_ => {
                _all    => { enabled => 0 },
                _source => { enabled => 0 },
                _type   => { index   => 'no' },
                enabled => 0,
            }
        }
    );
    $es->cluster_health( wait_for_status => 'yellow' );
    return $self;
}

#===================================
sub index { shift->{_index} }
sub es    { shift->{_es} }
#===================================

#===================================
sub delete_type {
#===================================
    my $self = shift;
    my $type = shift;
    croak "No type passed to delete_type()"
        unless defined $type and length $type;

    $self->es->delete_mapping(
        index          => $self->index,
        type           => $type,
        ignore_missing => 1
    );
    return $self;
}

#===================================
sub delete_index {
#===================================
    my $self = shift;
    $self->es->delete_index( index => $self->index, ignore_missing => 1 );
    return $self;
}

1;

# ABSTRACT: Track unique keys in ElasticSearch

__END__

=pod

=encoding UTF-8

=head1 NAME

ElasticSearchX::UniqueKey - Track unique keys in ElasticSearch

=head1 VERSION

version 0.05

=head1 SYNOPSIS

    use Search::Elasticsearch::Compat();
    use ElasticSearchX::UniqueKey();

    my $es   = Search::Elasticsearch::Compat->new();
    my $uniq = ElasticSearchX::UniqueKey->new( es => $es );

    $uniq->bootstrap();

    $created = $uniq->create( $key_name, $key_id );
    $deleted = $uniq->delete( $key_name, $key_id );
    $exists  = $uniq->exists( $key_name, $key_id );
    $updated = $uniq->update( $key_name, $old_id, $new_id );

    %failed  = $uniq->multi_create(
        $key_name_1 => $key_id_1,
        $key_name_2 => $key_id_2,
    );

    $uniq->multi_delete(
        $key_name_1 => $key_id_1,
        $key_name_2 => $key_id_2,
    )

    %failed = $uniq->multi_update(
        { key_1 => 'old', key_2 => 'old' },
        { key_1 => 'new', key_2 => 'new' },
    );

    %failed  = $uniq->multi_exists(
        $key_name_1 => $key_id_1,
        $key_name_2 => $key_id_2,
    );

    $uniq->delete_index;
    $uniq->delete_type( $key_name );

=head1 DESCRIPTION

The only unique key available in Elasticsearch is the document ID. Typically,
if you want a document to be unique, you use the unique value as the ID.
However, sometimes you don't want to do this. For instance, you may want
to use the email address as a unique identifier for your user accounts, but
you also want to be able to link to a user account without exposing their email
address.

L<ElasticSearchX::UniqueKey> allows you to keep track of unique values by
maintaining a dedicated index which can contain multiple C<types>.  Each
C<type> represents a different key name (so a single index can be used
to track multiple unique keys).

=head1 METHODS

=head2 new()

    my uniq = ElasticSearchX::UniqueKey->new(
        es      => $es,         # Search::Elasticsearch::Compat instance, required
        index   => 'index',     # defaults to 'unique_key',
    );

C<new()> returns a new instance of L<ElasticSearchX::UniqueKey>. The unique
keys are stored in the specified index, which is setup to be very efficient
for this purpose, but not useful for general storage.

You must call L</bootstrap()> to create your index before first using it,
otherwise it will not be setup correctly.
See L</"bootstrap()"> for how to initiate your index.

You don't need to setup your C<key_names> (ie your C<types>) - these will
be created automatically.

=head2 create()

    $created = $uniq->create( $key_name, $key_id );

Returns true if the C<key_name/key_id> combination didn't already exist and
it has been able to create it.  Returns false if it already exists.

=head2 delete()

    $deleted = $uniq->delete( $key_name, $key_id );

Returns true if the C<key_name/key_id> combination existed and it has been
able to delete it. Returns false if it didn't already exist.

=head2 exists()

    $exists = $uniq->exists( $key_name, $key_id );

Returns true or false depending on whether the C<key_name/key_id> combination
exists or not.

=head2 update()

    $updated = $uniq->update( $key_name, $old_id, $new_id );

First tries to create the new combination C<key_name/new_id>, otherwise
returns false.  Once created, it then tries to delete the
C<key_name/old_id>, and returns true regardless of whether it existed previously
or not.

=head2 multi_create()

    %failed = $uniq->multi_create(
        $key_name_1 => $key_id_1,
        $key_name_2 => $key_id_2,
    );

Use L</multi_create()> to create several entries at the same time (each
C<$key_name> must be different).  If it fails to create all the entries,
then it will remove any entries that it succeeded in creating, and
return a hash of the entries which failed.

=head2 multi_delete()

    $uniq->multi_delete(
        $key_name_1 => $key_id_1,
        $key_name_2 => $key_id_2,
    );

Use L</multi_delete()> to delete several entries at the same time (each
C<$key_name> must be different).  Returns 1 whether the entries exist or not.

=head2 multi_update()

    %failed = $uniq->multi_update( \%old, \%new );

L</multi_update()> first tries to create the new keys, then deletes the old
keys. Returns a hash of any entries that couldn't be created.

=head2 multi_delete()

    %failed = $uniq->multi_exists(
        $key_name_1 => $key_id_1,
        $key_name_2 => $key_id_2,
    );

Returns a hash of any entries that don't exist.

=head2 bootstrap()

    $uniq->bootstrap( %settings );

This method will create the index, if it doesn't already exist.
By default, the index is setup with the following C<%settings>:

    (
        number_of_shards     => 1,
        auto_expand_replicas => '0-all',
    )

In other words, it will have only a single primary shard (instead of the
Elasticsearch default of 5), and a replica of that shard on every Elasticsearch
node in your cluster.

If you pass in any C<%settings> then the defaults will not be used at all.

See L<Index Settings|http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/indices-update-settings.html> for more.

=head2 delete_index()

    $uniq->delete_index()

Deletes the index. B<You will lose your data!>

=head2 delete_type()

    $uniq->delete_type( $key_name )

Deletes the type associated with the C<key_name>. B<You will lose your data!>

=head2 index()

    $index = $uniq->index

Read-only getter for the index value

=head2 es()

    $es = $uniq->es

Read-only getter for the Search::Elasticsearch::Compat instance.

=head1 SEE ALSO

=over

=item L<Search::Elasticsearch::Compat>

=item L<Elastic::Model>

=item L<http://www.elasticsearch.org>

=back

=head1 BUGS

This is a new module, so there will probably be bugs, and the API may change
in the future.

If you have any suggestions for improvements, or find any bugs, please
report them to http://github.com/clintongormley/ElasticSearchX-UniqueKey/issues. I
will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 TEST SUITE

The full test suite requires a live Elasticsearch cluster to run.  CPAN
testers doesn't support this.  You can see full test results here:
L<http://travis-ci.org/#!/clintongormley/ElasticSearchX-UniqueKey/builds>.

To run the full test suite locally, run it as:

    perl Makefile.PL
    ES_HOME=/path/to/elasticsearch make test

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc ElasticSearchX::UniqueKey

You can also look for information at:

=over

=item * GitHub

L<http://github.com/clintongormley/ElasticSearchX-UniqueKey>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/ElasticSearchX-UniqueKey>

=item * Search MetaCPAN

L<https://metacpan.org/module/ElasticSearchX::UniqueKey>

=back

=head1 AUTHOR

Clinton Gormley <drtech@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Clinton Gormley.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
