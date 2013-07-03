package Doc::Tree;

use Moose;

use common::sense;
use Data::Dump;
use HTML::Entities;
use Pod::Simple::SimpleTree;
use Readonly;

# A POD document is divided into a tree of elements, each represented as
# *either* an arrayref of size 3 or more, or a simple scalar.
# In case of an arrayref, the values are the name of the element
# (e.g. 'head3', 'Para'), a hashref of attributes, and one or more
# sub-elements. So get used to dealing with arrayrefs, and use these
# constants for readability.

Readonly::Scalar my $NAME         => 0;
Readonly::Scalar my $ATTRIBUTES   => 1;
Readonly::Scalar my $SUB_ELEMENTS => 2;

=head1 NAME

Doc::Tree - a tree-based parser for the doc viewer

=head1 SYNOPSIS

Used by the doc viewer internally.

=head1 DESCRIPTION

A Moose class for parsing and manipulating POD from Dancer route definition
modules. It knows how to build the data structures needed for the doc viewer,
and implements directives for merging input and output sections of routes
with other other routes.

=head2 Attributes

=over

=item pod_tree

A POD tree, being an arrayref of nested POD elements, as generated by
Pod::Simple::SimpleTree. Read-only, so must be specified at constructor time,
typically by L<new_from_file>. It is then immediately massaged to add
specific information (like shortcuts) to the POD.

=cut

has 'pod_tree' => (
    is       => 'ro',
    isa      => 'ArrayRef',
    required => 1,
    trigger  => \&_massage_pod_tree,
);

sub _pod_tree_guts {
    my ($self) = @_;
    return $self->meta->find_attribute_by_name('pod_tree')->get_value($self);
}

has '_no_dl_munging' => (
    is  => 'ro',
    isa => 'Bool',
);

sub _massage_pod_tree {
    my ($self) = @_;

    # Pull in the input and/or output sections of routes to other routes.
    $self->_merge_route_definitions;

    # Now that we have all of our <dl> equivalents, style them.
    $self->_add_dl_attributes($self->pod_tree) unless $self->_no_dl_munging;
}

sub _add_dl_attributes {
    my ($self, $parent_element, $dl_class) = @_;

    # Style all over-text (<dl>) elements according to the most recent head4,
    # or the class we were passed if this is a sub-<dl>.
    element:
    for my $element ($self->sub_elements($parent_element)) {
        next element if !ref($element);
        given ($element->[$NAME]) {
            when ('head4') {
                given ($element->[$SUB_ELEMENTS]) {
                    when ('Input')  { $dl_class = 'input-params' }
                    when ('Output') { $dl_class = 'output-params' }
                }
            }
            when ('over-text') {
                if ($dl_class) {
                    $element->[$ATTRIBUTES]->{html_attributes}{class}
                        = $dl_class;
                    $self->_add_dl_attributes($element, $dl_class);
                }

            }
        }
    }
}

sub _merge_route_definitions {
    my ($self) = @_;

    # Walk the tree looking for special docviewer directives.
    my ($current_head3);
    for my $element ($self->sub_elements($self->pod_tree)) {
        if ($element->[$NAME] eq 'head3') {
            $current_head3 = ($self->text_elements($element))[0];
        } elsif ($element->[$NAME] eq 'for'
            && $element->[$ATTRIBUTES]{target} eq 'docviewer')
        {
            for my $command ($self->search_element($element, 'Data')) {
                if ($command
                    =~ /^ (?<type> input|output )-from \s (?<route> .+ ) /x)
                {
                    $self->_import_pod(
                        source_head3 => $+{route},
                        dest_head3   => $current_head3,
                        type         => ucfirst($+{type}),
                    );
                    $element->[$ATTRIBUTES]{delete} = 1;
                }
            }
        }
    }

    # Now that we've done this, remove all the special markers.
    my $pod_tree = $self->_pod_tree_guts;
    my $found_element;
    do {
        $found_element = 0;
        element:
        for my $element_num ($SUB_ELEMENTS .. $#{ $pod_tree }) {
            my $element = $self->pod_tree->[$element_num];
            if ($element->[$ATTRIBUTES]{delete}) {
                splice(@$pod_tree, $element_num, 1);
                $found_element = 1;
                last element;
            }
        }
    } while ($found_element);
}

# A lookup of <dl>-equivalent elements in the POD tree, by parent head3
# and parent head4. (Well, not parent, as all of this stuff is adjacent,
# but the head3 and head4 they logically fall under.)

has '_dl_elements' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__dl_elements {
    my ($self) = @_;
    
    # Find all input and output sections.
    my (%element_dl, $current_head3, $current_head4);
    for my $element ($self->sub_elements($self->pod_tree)) {
        given ($element->[$NAME]) {
            when (['head1', 'head2']) {
                undef $current_head3;
                undef $current_head4;
            }
            when ('head3') {
                $current_head3 = ($self->text_elements($element))[0];
                undef $current_head4;
            }
            when ('head4') {
                $current_head4 = ($self->text_elements($element))[0];
            }
            when ('over-text') {
                $element_dl{$current_head3}{$current_head4} = $element;
            }
        }
    }
    return \%element_dl;
}

sub _import_pod {
    my ($self, %args) = @_;
 
    if (!$self->_dl_elements->{$args{dest_head3}}->{$args{type}}) {
        $self->_ensure_head4_and_dl(
            parent_head3 => $args{dest_head3},
            type         => $args{type}
        );
    }
    $self->_merge_dl_structures(
        source => $self->_dl_elements->{$args{source_head3}}->{$args{type}},
        dest   => $self->_dl_elements->{$args{dest_head3}}  ->{$args{type}},
    );
}

sub _ensure_head4_and_dl {
    my ($self, %args) = @_;

    my $pod_tree = $self->_pod_tree_guts;

    # OK, go through the tree looking for a head3, then a head4, then
    # a <dl>. If we ever encounter something unexpected, after we'd
    # found the beginning of the sequence, we need to insert the missing
    # records.
    my ($found_desired_head3, $found_desired_head4, $found_desired_dl);
    element:
    for my $element_num ($SUB_ELEMENTS .. $#{$pod_tree}) {
        my $element      = $pod_tree->[$element_num];
        my $element_text = ($self->text_elements($element))[0];
        given ($element->[$NAME]) {
            when ('head3') {
                # If this is our head3, hooray.
                # If it's something else, and we've found our head3,
                # this means that our head3 didn't include some or all
                # of the things we expect (as we'd have bailed out otherwise).
                if ($element_text eq $args{parent_head3}) {
                    $found_desired_head3 = 1;
                } elsif ($found_desired_head3) {
                    if (!$found_desired_head4) {
                        $self->_splice_head4($element_num++, $args{type});
                        $found_desired_head4 = 1;
                    }
                    if (!$found_desired_dl) {
                        $found_desired_dl = $self->_splice_dl($element_num);
                    }
                    last element;
                }
            }
            when ('head4') {
                if ($found_desired_head3) {
                    # If this is what we expected, hooray. If this is Output
                    # and we wanted Input, Input isn't going to happen, so
                    # put it here.
                    if ($element_text eq $args{type}) {
                        $found_desired_head4 = 1;
                    } elsif ($args{type} eq 'Input'
                        && $element_text eq 'Output')
                    {
                        $self->_splice_head4($element_num++, $args{type});
                        $found_desired_dl = $self->_splice_dl($element_num++);
                        $found_desired_head4 = 1;
                        last element;
                    }
                }
            }
            when ('over-text') {
                if ($found_desired_head4) {
                    $found_desired_dl = $element;
                    last element;
                }
            }
        }
    }
    # If we didn't find a head4 at all, we've got to the end of the list,
    # so add it to the end.
    if (!$found_desired_head4) {
        $self->_splice_head4($#{ $pod_tree } + 1, $args{type});
        $found_desired_dl = $self->_splice_dl($#{ $pod_tree } + 1);
    }

    # Remember this for future reference.
    $self->_dl_elements->{ $args{parent_head3} }{ $args{type} }
        ||= $found_desired_dl;
}

sub _splice_head4 {
    my ($self, $pos, $contents) = @_;

    splice(
        @{ $self->_pod_tree_guts }, $pos, 0,
        ['head4', {}, $contents]
    );
}

sub _splice_dl {
    my ($self, $pos) = @_;

    my $dl = ['over-text', { indent => 4, '~type' => 'text' }, ''];
    splice(@{ $self->_pod_tree_guts }, $pos, 0, $dl);
    return $dl;
}

sub _merge_dl_structures {
    my ($self, %args) = @_;

    # Turn this collection of elements into a hash for easy manipulation.
    my %source_definition = $self->_parse_definitions($args{source});
    my %dest_definition = $self->_parse_definitions($args{dest});

    # Go through adding things to the destination list, recursing if
    # necessary (e.g. if they both define the same top-level item).
    for my $term (sort keys %source_definition) {
        if (!exists $dest_definition{$term}) {
            $dest_definition{$term} = $source_definition{$term};
        } else {
            $self->_merge_dl_structures(
                source => $source_definition{$term}[0],
                dest   => $dest_definition{$term}[0],
            );
        }
    }

    # Now update our destination element.
    # Clear out all the sub-elements.
    splice(@{$args{dest}}, $SUB_ELEMENTS);

    # And put the new ones back in, sorted.
    for my $term (sort keys %dest_definition) {
        push @{ $args{dest} },
            ['item-text', { '~type' => 'text' }, $term],
            $dest_definition{$term}[0];
    }
}

sub _parse_definitions {
    my ($self, $element) = @_;

    my @tag_pairs = $self->_tag_pairs($element);
    my %definition
        = map { ($self->text_elements($_->{term}))[0] => $_->{definition} }
        @tag_pairs;
    return %definition;
}

sub _tag_pairs {
    my ($self, $element) = @_;

    my @tag_pairs;
    for my $element ($self->sub_elements($element)) {
        if (ref($element) && $element->[$NAME] eq 'item-text') {
            push @tag_pairs, { term => $element, definition => [] };
        } else {
            push @{ $tag_pairs[-1]{definition} }, $element
                if @tag_pairs;
        }
    }
    return @tag_pairs;
}

=item file_path

A string representing the path of the file being analysed. Read-only, so
must be specified at constructor time.

=cut

has 'file_path' => (
    is => 'ro',
    isa => 'Str',
);

=item ids_used

A hashref of IDs used by any generating code. Mostly for internal use, but can
be updated to tell this object that there are additional IDs it shouldn't
accidentally re-use (e.g. IDs used by a previous Doc::Tree object, where
multiple objects' output is going to be used on the same page).

=cut

has 'ids_used' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

=item routes

A hashref of ID => route description HTML (i.e. only the POD under a head3
or a head4). Lazily-built.

=cut

has 'routes' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_routes {
    my ($self) = @_;

    my (%routes, $current_route_id);
    for my $element ($self->sub_elements($self->pod_tree)) {
        if ($element->[$NAME] eq 'head3') {
            $current_route_id
                = $self->id_from_text(($self->text_elements($element))[0]);
        } elsif ($element->[$NAME] =~ /head[12]/) {
            undef $current_route_id;
        }
        if ($current_route_id) {
            push @{ $routes{$current_route_id} },
                $self->render_as_html($element);
        }
    }
    return \%routes;
}

=item index

A string containing HTML used to generate an index of all the sections and
routes in this tree. Lazily-built.

=cut

has 'index' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

=item module_id

A unique ID identifying this Dancer module.

=cut

has 'module_id' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_module_id {
    my ($self) = @_;
    $self->id_from_text(
        $self->file_path =~ s{^ .+ / lib / (.+) [.] pm $}{$1}rix);
}

sub _build_index {
    my ($self) = @_;

    my $html_index;
    for my $element ($self->search_tree(['head1', 'head3'])) {
        if ($element->[$NAME] eq 'head1') {
            $self->_add_module_header(
                html    => \$html_index,
                content => $element->[$SUB_ELEMENTS],
            );
        } else {
            $self->_add_route_entry(
                html  => \$html_index,
                route => $element->[$SUB_ELEMENTS],
            );
        }
    }
    $self->_add_to_html(
        html   => \$html_index,
        indent => 2,
        lines  => ['</ul>', '</li>', '</ul>']
    );
    return $html_index;
}

sub _add_module_header {
    my ($self, %args) = @_;

    my $module_id = $self->module_id;
    my $accordion = qq{data-toggle="collapse" data-target=".$module_id"}
        . q{ data-parent="#sidebar"};
    $self->_add_to_html(
        html   => $args{html},
        indent => 0,
        lines  => [
            '<ul>',
            '<li>',
            qq{<a href="#!/$module_id-pod" $accordion id="$module_id"}
                . q{ class="pod-link showpanel">Full POD</a>},
            qq{<a href="#!/$module_id" $accordion class="sidebar-header">}
                . qq{$args{content}</a>},
            qq{<ul class="collapse route-list $module_id">},
        ]
    );
}

sub _add_route_entry {
    my ($self, %args) = @_;

    my $id = $self->id_from_text($args{route}, 1);
    $args{route} = HTML::Entities::encode_entities($args{route});
    my $styled_route
        = $args{route} =~ s{(ANY|GET|POST|PUT|PATCH|DELETE)}{<i>$1</i>}ir;
    $self->_add_to_html(
        html   => $args{html},
        indent => 3,
        lines  => [
            qq{<li><a href="#!/$id" class="showpanel" id="$id"}
          . qq{ title="$args{route}">$styled_route</a></li>}
        ]
    );
}

sub _add_to_html {
    my ($self, %args) = @_;

    for my $line (@{$args{lines}}) {
        ${$args{html}} .= '  ' x $args{indent} . $line . "\n";
        if ($line =~ m{< (?<down> /)? (?<tag> ul|li) }xi) {
            $args{indent} += $+{down} ? -1 : 1;
        }
    }
}

=back

=head2 Class methods

=over

=item new_from_file

 In: $file_path
 Out: $tree

Supplied with a file path, returns a Doc::Tree object for it, with the
pod_tree attribute pre-filled.

=cut

sub new_from_file {
    my ($class, $file_path) = @_;

    my $simple_tree = Pod::Simple::SimpleTree->new;
    $simple_tree->accept_targets('docviewer');
    $simple_tree->parse_file($file_path);
    my $pod_tree = $simple_tree->root;
    die if !$pod_tree;
    return $class->new(pod_tree => $pod_tree, file_path => $file_path);
}

=back

=head2 Object methods

=over

=item text_elements

 In: @elements
 Out: @text_nodes

Supplied with an array of elements, returns just the text nodes. Will
probably break if you give it a very complex tree.

=cut

sub text_elements {
    my ($self, @elements) = @_;

    return
        map { ref($_) eq 'ARRAY' ? $self->sub_elements($_) : $_ }
        @elements;
}

=item sub_elements

 In: $element

Supplied with an element arrayref, returns the sub-element(s).

=cut

sub sub_elements {
    my ($self, $element) = @_;

    return @$element[$SUB_ELEMENTS .. $#$element];
}

=item search_tree

 In: $element_name
 Out: @elements

Supplied with an element name (e.g. 'head3'), searches the pod tree
recursively for all elements of that name.

If you specify a single scalar element name, will return the sub nodes of
all matching elements (often just text if e.g. you're looking for headings
or docviewer Data).

If you specify an arrayref of possible element names, will return all
matching elements.

=cut

sub search_tree {
    my ($self, $element_name) = @_;

    return $self->search_element($self->pod_tree, $element_name);
}

=item search_element

 In: $element
 In: $element_name
 Out: @elements

As search_tree, but starts from an arbitrary element.

=cut

sub search_element {
    my ($self, $element, $want_element_name) = @_;

    # If this is just a text element, that's no good.
    return if !ref($element);

    # If this is the element we're looking for, jackpot.
    if ($element->[$NAME] ~~ $want_element_name) {
        return
            ref($want_element_name) eq 'ARRAY'
            ? $element
            : $self->sub_elements($element);
    }

    # OK, go looking for any elements under this one, if any.
    my @matched_elements;
    for my $sub_element ($self->sub_elements($element)) {
        push @matched_elements,
            $self->search_element($sub_element, $want_element_name);
    }
    return @matched_elements;
}

=item render_as_html

 In: $element (optional)
 Out: $html

Supplied with an element (optional; if omitted uses pod_tree), turns it into
HTML.

=cut

sub render_as_html {
    my ($self, $element) = @_;

    $element ||= $self->pod_tree;
    return $self->_element_as_html($element);
}

sub _element_as_html {
    my ($self, $element) = @_;

    # If this is a simple scalar, turn it into HTML.
    if (!ref $element) {
        return $self->_html_from_text($element);
    }

    # Otherwise this depends on the nature of the element.
    given ($element->[$NAME]) {
        when ('Document') {
            return $self->_sub_elements_as_html($element);
        }
        when (/^ head (?<level> \d ) $/x) {
            return "\n" . $self->_tag("h$+{level}", $element) . "\n";
        }

        when ('Para')      { return $self->_tag('p', $element);    }
        when ('over-text') { return $self->_dl($element);          }
        when ('I')         { return $self->_tag('i', $element);    }
        when ('B')         { return $self->_tag('b', $element);    }
        when ('C')         { return $self->_tag('code', $element); }
        when ('Verbatim')  { return $self->_tag('pre', $element);  }
        when ('L')         { return $self->_link($element);        }

        default {
            if (!ref($element->[$SUB_ELEMENTS])) {
                die Data::Dump::dump('No idea what to do with', $element);
            } else {
                print STDERR "Unrecognised block element "
                    . $element->[$NAME] . "\n";
                return $self->_element_as_html($element->[$SUB_ELEMENTS]);
            }
        }
    }
}

sub _html_from_text {
    my ($self, $element) = @_;

    # First off, encode into entities any special characters.
    my $html = HTML::Entities::encode_entities($element);

    # Style TODO and FIXME
    for ([FIXME => 'label-important'], [TODO => 'label-warning']) {
        my ($word, $class) = @$_;
        $html =~ s{$word:?}{<span class="label $class">$word</span>}g;
    }

    # Turn references to other routes into links.
    $html =~ s{
		( (?:ANY|GET|POST|PUT|PATCH|DELETE) \s /\S+ )
	}{"<a href=\"#!/" . $self->id_from_text($1, 1) . "\">$1</a>"}exg;
    
    return $html;
}


sub _dl {
    my ($self, $element) = @_;

    # Build up the <dl> tag manually, because the contents are
    # going to be hand-assembled tags.
    my $html
        = $self->_beginning_tag('dl',
        $element->[$ATTRIBUTES]{html_attributes})
        . "\n";

    # Go through the definition list hand-assembling tags.
    for my $tag_pair ($self->_tag_pairs($element)) {
        $html .= $self->_tag('dt', $tag_pair->{term});
        $html .= '<dd>'
            . join('',
                   map { $self->_element_as_html($_) }
                   @{ $tag_pair->{definition} })
            . '</dd>';
    }

    $html .= "\n</dl>\n";
    return $html;
}


sub _link {
    my ($self, $element) = @_;

    my $attributes = $element->[$ATTRIBUTES];
    my $url;
    if (exists $attributes->{to}) {
        $url = $attributes->{to}->as_string;
        if ($attributes->{type} eq 'pod') {
            $url = 'https://metacpan.org/module/' . $url;
        }
    }
    if (exists $attributes->{section}) {
        $url .= '#'
            . $self->id_from_text($attributes->{section}->as_string, 1);
    }
    $attributes->{html_attributes}{href} = $url;
    return $self->_tag('a', $element);
}


sub _sub_elements_as_html {
    my ($self, $element) = @_;

    return join('',
        map { $self->_element_as_html($_) } $self->sub_elements($element));
}

sub _tag {
    my ($self, $tag_name, $element) = @_;

    return $self->_beginning_tag($tag_name,
        $element->[$ATTRIBUTES]->{html_attributes})
        . ($element->[$ATTRIBUTES]->{line_feeds} ? "\n" : '')
        . $self->_sub_elements_as_html($element)
        . ($element->[$ATTRIBUTES]->{line_feeds} ? "\n" : '')
        . "</$tag_name>";
}

sub _beginning_tag {
    my ($self, $tag_name, $attributes) = @_;

    my $html = "<$tag_name";
    for my $attribute_name (sort keys %$attributes) {
        $html .= qq{ $attribute_name="$attributes->{$attribute_name}"};
    }
    $html .= '>';
    return $html;
}

=item id_from_text

 In: $text
 In: $not_unique
 Out: $id

Supplied with source text (which can be HTML or anything), and whether this
ID needs to be unique, generates an ID for use in HTML. If $not_unique is
true, it ensures the ID is unique among all IDs generated so far.

=cut

sub id_from_text {
    my ($self, $text, $not_unique) = @_;

    # Colons and periods are valid in HTML IDs, but jQuery can't easily 
    # use them in selectors - you have to escape them, and it's a pain
    # So for ease of use on the front end, get rid of them

    my $id = lc $text;
    for ($id) {
        s/<[^>]+>//g;            # Strip HTML.
        s/&[^;]+;//g;            # Strip entities.
        s/^\s+//; s/\s+$//;      # Strip white space.
        s/^([^a-zA-Z]+)$/pod$1/; # Prepend "pod" if no valid chars.
        s/^[^a-zA-Z]+//;         # First char must be a letter.
        s/[^-a-zA-Z0-9_]+/-/g;   # All other chars must be valid.
    }

    return $id if $not_unique;
    my $suffix = '';
    $suffix++ while $self->{ids_used}{"$id$suffix"}++;
    return "$id$suffix";
}

__PACKAGE__->meta->make_immutable;
1;
