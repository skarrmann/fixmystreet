=head1 NAME

FixMyStreet::Cobrand::Brent - code specific to the Brent cobrand

=head1 SYNOPSIS

Brent is a London borough using FMS and WasteWorks

=cut

package FixMyStreet::Cobrand::Brent;
use parent 'FixMyStreet::Cobrand::UKCouncils';

use Moo;

# We use the functionality of bulky waste, though it's called small items
with 'FixMyStreet::Roles::Cobrand::Waste';
with 'FixMyStreet::Roles::Cobrand::BulkyWaste';

use strict;
use warnings;
use Moo;
use DateTime;
use DateTime::Format::Strptime;
use Try::Tiny;
use LWP::Simple;
use URI;
use JSON::MaybeXS;

=head1 INTEGRATIONS

Integrates with Echo and Symology for FixMyStreet

Integrates with Echo for WasteWorks.

Uses SCP for accepting payments.

Uses OpenUSRN for locating nearest addresses on the Highway

=cut

use FixMyStreet::App::Form::Waste::Request::Brent;
use FixMyStreet::App::Form::Waste::Garden::Sacks;
use FixMyStreet::App::Form::Waste::Garden::Sacks::Renew;
with 'FixMyStreet::Roles::Open311Multi';
with 'FixMyStreet::Roles::Cobrand::OpenUSRN';
with 'FixMyStreet::Roles::Cobrand::Echo';
with 'FixMyStreet::Roles::Cobrand::SCP';
use Integrations::Paye;

# Brent covers some of the areas around it so that it can handle near-boundary reports
sub council_area_id { return [2488, 2505, 2489, 2487]; } # 2505 Camden, 2489 Barnet, 2487 Harrow
sub council_area { return 'Brent'; }
sub council_name { return 'Brent Council'; }
sub council_url { return 'brent'; }

my $BRENT_CONTAINERS = {
    1 => 'Blue rubbish sack',
    16 => 'General rubbish bin (grey bin)',
    8 => 'Clear recycling sack',
    6 => 'Recycling bin (blue bin)',
    11 => 'Food waste caddy',
    13 => 'Garden waste (green bin)',
    46 => 'Paper and cardboard blue sack',
};

=head1 DESCRIPTION

=cut

=head2 FMS Defaults

=over 4

=cut

=item * Use their own brand colours for pins

=cut

sub path_to_pin_icons {
    return '/cobrands/oxfordshire/images/';
}

=item * Users with a brent.gov.uk email can always be found in the admin.

=cut

sub admin_user_domain { 'brent.gov.uk' }

=item * Allows anonymous reporting

=cut

sub allow_anonymous_reports { 'button' }

=item * Has a default map zoom of 5

=cut

sub default_map_zoom { 5 }

=item * Doesn't show reports before go live date 2023-03-06

=cut

sub cut_off_date { '2023-03-06'}

=item * Uses their own privacy policy

=cut

sub privacy_policy_url {
    'https://www.brent.gov.uk/the-council-and-democracy/access-to-information/data-protection-and-privacy/brent-privacy-policy'
}

=item * Uses the OSM geocoder

=cut

sub get_geocoder { 'OSM' }

=item * Doesn't allow the reopening of reports

=cut

sub reopening_disallowed { 1 }

=item * Uses slightly different text on the geocode form.

=cut

sub enter_postcode_text {
    my ($self) = @_;
    return 'Enter a ' . $self->council_area . ' postcode, or street name';
}

=item * Only returns search results from Brent

=cut

sub disambiguate_location { {
    centre => '51.5585509362304,-0.26781886445231',
    span   => '0.0727325098393763,0.144085171830317',
    bounds => [ 51.52763684136, -0.335577710963202, 51.6003693511994, -0.191492539132886 ],
    town => 'Brent',
} }

=item * Filters down search results to be the street name and the postcode only

=back

=cut

sub geocoder_munge_results {
    my ($self, $result) = @_;

    $result->{display_name} =~ s/, London Borough of Brent, London, Greater London, England//;
}

=head2 check_report_is_on_cobrand_asset

If the location is covered by an area of differing responsibility (e.g. Brent
in Camden, or Camden in Brent), return the name of the area.

=cut

sub check_report_is_on_cobrand_asset {
    my $self = shift;

    my $lat = $self->{c}->stash->{latitude};
    my $lon = $self->{c}->stash->{longitude};
    my $host = FixMyStreet->config('STAGING_SITE') ? "tilma.staging.mysociety.org" : "tilma.mysociety.org";

    my $cfg = {
        url => "https://$host/mapserver/brent",
        srsname => "urn:ogc:def:crs:EPSG::4326",
        typename => "BrentDiffs",
        filter => "<Filter><Contains><PropertyName>Geometry</PropertyName><gml:Point><gml:coordinates>$lon,$lat</gml:coordinates></gml:Point></Contains></Filter>",
        outputformat => 'GML3',
    };

    my $features = $self->_fetch_features($cfg, -1, -1, 1);

    if ($$features[0]) {
        return $$features[0]->{'ms:BrentDiffs'}->{'ms:name'};
    }
}

=head2 munge_overlapping_asset_bodies

Alters the list of available bodies for the location,
depending on calculated responsibility. After this function,
the bodies list will be the relevant bodies for the point,
though categories may need to be altered later on.

=cut

sub munge_overlapping_asset_bodies {
    my ($self, $bodies) = @_;

    # in_area will be true if the point is within the administrative area of Brent
    my $in_area = grep ($self->council_area_id->[0] == $_, keys %{$self->{c}->stash->{all_areas}});
    # cobrand will be true if the point is within an area of different responsibility from the norm
    my $cobrand = $self->check_report_is_on_cobrand_asset;

    if ($in_area) {
        # In the area of Brent...
        if (!$cobrand || $cobrand eq 'Brent') {
            # ...Brent's responsibility - remove the other bodies covering the Brent area
            %$bodies = map { $_->id => $_ } grep {
                $_->get_column('name') ne 'Camden Borough Council' &&
                $_->get_column('name') ne 'Barnet Borough Council' &&
                $_->get_column('name') ne 'Harrow Borough Council'
                } values %$bodies;
        } else {
            # Camden wants sole responsibility of Camden agreed areas
            if ($cobrand eq 'Camden') {
                %$bodies = map { $_->id => $_ } grep {
                    $_->get_column('name') eq 'Camden Borough Council' || $_->get_column('name') eq 'TfL' || $_->get_column('name') eq 'National Highways'
                } values %$bodies;
                return;
            }
            # ...someone else's responsibility, take out the ones definitely not responsible
            my %cobrands = (Harrow => 'Harrow Borough Council', Barnet => 'Barnet Borough Council');
            my $selected = $cobrands{$cobrand};
            %$bodies = map { $_->id => $_ } grep {
                $_->get_column('name') eq $selected || $_->get_column('name') eq 'Brent Council' || $_->get_column('name') eq 'TfL' || $_->get_column('name') eq 'National Highways'
            } values %$bodies;
        }
    } else {
        # Not in the area of Brent...
        if (!$cobrand || $cobrand ne 'Brent') {
            # ...not Brent's responsibility - remove Brent
            %$bodies = map { $_->id => $_ } grep {
                $_->get_column('name') ne 'Brent Council'
                } values %$bodies;
        } else {
            # If it's for Brent shared with Camden, make wholly Brent's responsibility
            if (grep { $_->get_column('name') eq 'Camden Borough Council' } values %$bodies) {
                %$bodies = map { $_->id => $_ } grep {
                    $_->get_column('name') eq 'Brent Council' || $_->get_column('name') eq 'TfL' || $_->get_column('name') eq 'National Highways'
                } values %$bodies;
            }
        }
    }
}

=head2 munge_cobrand_asset_categories

If we're in an overlapping area, we want to take the street categories
of one body, and the non-street categories of the other.

=cut

sub munge_cobrand_asset_categories {
    my ($self, $contacts) = @_;

    my %bodies = map { $_->body->get_column('name') => $_->body } @$contacts;
    my %non_street = (
        'Barnet' => { map { $_ => 1 } @{ $self->_barnet_non_street } },
        'Harrow' => { map { $_ => 1 } @{ $self->_harrow_non_street } },
    );

    # in_area will be true if the point is within the administrative area of Brent
    my $in_area = grep ($self->council_area_id->[0] == $_, keys %{$self->{c}->stash->{all_areas}});
    # cobrand will be true if the point is within an area of different responsibility from the norm
    my $cobrand = $self->check_report_is_on_cobrand_asset || '';

    return unless $cobrand;

    my $brent_body = $self->body->id;
    if (!$in_area && $cobrand eq 'Brent') {
        # Outside the area of Brent, but Brent's responsibility
        my $area;
        # Camden do not mix categories with Brent
        if (grep {$_->{name} eq 'Camden Borough Council'} values %{$self->{c}->stash->{all_areas}}){
            return;
        } elsif (grep {$_->{name} eq 'Harrow Borough Council'} values %{$self->{c}->stash->{all_areas}}) {
            $area = 'Harrow';
        }  elsif (grep {$_->{name} eq 'Barnet Borough Council'} values %{$self->{c}->stash->{all_areas}}) {
            $area = 'Barnet';
        };
        my $other_body = $bodies{$area . " Borough Council"};

        # Remove the non-street contacts of Brent
        @$contacts = grep { !($_->email !~ /^Symology/ && $_->body_id == $brent_body) } @$contacts;
        # Remove the street contacts of the other
        @$contacts = grep { !(!$non_street{$area}{$_->category} && $_->body_id == $other_body->id) } @$contacts
            if $other_body;
    } elsif ($in_area && $cobrand ne 'Brent') {
        if ($cobrand eq 'Camden') {
            return;
        }
        # Inside the area of Brent, but not Brent's responsibility
        my $other_body = $bodies{$cobrand . " Borough Council"};
        # Remove the street contacts of Brent
        @$contacts = grep { !($_->email =~ /^Symology/ && $_->body_id == $brent_body) } @$contacts;
        # Remove the non-street contacts of the other
        @$contacts = grep { !($non_street{$cobrand}{$_->category} && $_->body_id == $other_body->id) } @$contacts
            if $other_body;
    }
}

=head2 pin_colour

=over 4

=item * grey: closed

=item * green: fixed

=item * yellow: confirmed

=item * orange: all other open states, like "in progress"

=back

=cut

sub pin_colour {
    my ( $self, $p, $context ) = @_;
    return 'grey' if $p->is_closed;
    return 'green' if $p->is_fixed;
    return 'yellow' if $p->state eq 'confirmed';
    return 'orange'; # all the other `open_states` like "in progress"
}

=head2 categories_restriction

Doesn't show TfL's River Piers category as no piers in Brent.
Also don't show bus station category as only one in Brent and
never been used to report anything.

=cut

sub categories_restriction {
    my ($self, $rs) = @_;

    return $rs->search( { 'me.category' => [ '-and' => { '-not_like' => 'River Piers%' }, { '-not_like' => 'Bus Station%' }, { '-not_like' => '%(Response Desk Buses to Action)' } ] } );
}

=head2 social_auth_enabled, user_from_oidc, and oidc_config

=over 4

=cut

=item * Single sign on is enabled from the cobrand feature 'oidc_login'

=cut

sub social_auth_enabled {
    my $self = shift;

    return $self->feature('oidc_login') ? 1 : 0;
}

=item * Checks Brent specific fields for the single sign on name and email

=cut

sub user_from_oidc {
    my ($self, $payload) = @_;

    my $name = join(" ", $payload->{givenName}, $payload->{surname});
    my $email = $payload->{email};

    return ($name, $email);
}

=back

=cut

=item * Brent FMS and WasteWorks have separate OIDC configurations

This code figures out the correct OIDC config based on the hostname used
for the request.

=cut

sub oidc_config {
    my $self = shift;

    my $cfg = $self->{c}->cobrand->feature('oidc_login');
    my $host = $self->{c}->req->uri->host;

    if ($cfg->{hosts} && $cfg->{hosts}->{$host}) {
        return $cfg->{hosts}->{$host};
    }

    return $cfg;
}

=item * Show open reports for 3 months, closed/fixed for 1 month

=cut

sub report_age {
    return {
        open => '3 months',
        closed => '1 month',
        fixed  => '1 month',
    };
}

=head2 dashboard_export_problems_add_columns

Brent have various additional columns for extra report data.

=cut

sub dashboard_export_problems_add_columns {
    my ($self, $csv) = @_;

    $csv->add_csv_columns(
        (
            street_name => 'Street Name',
            location_name => 'Location Name',
            name => 'Created By',
            user_email => 'Email',
            usrn => 'USRN',
            uprn => 'UPRN',
            external_id => 'External ID',
            image_included => 'Does the report have an image?',

            InspectionDate => "Inspection date",
            GradeLitter => "Grade for Litter",
            GradeDetritus => "Grade for Detritus",
            GradeGraffiti => "Grade for Graffiti",
            GradeFlyPosting => "Grade for Fly-posting",
            GradeWeeds => "Grade for Weeds",
            GradeOverall => "Overall Grade",

            flytipping_did_you_see => 'Did you see the fly-tipping take place',
            flytipping_statement => "If 'Yes', are you willing to provide a statement?",
            flytipping_quantity => 'How much waste is there',
            flytipping_type => 'Type of waste',

            container_req_action => 'Container Request Action',
            container_req_type => 'Container Request Container Type',
            container_req_reason => 'Container Request Reason',

            email_renewal_reminders_opt_in => 'Email Renewal Reminders Opt-In',

            missed_collection_id => 'Service ID',
            map { "item_" . $_ => "Small Item $_" } (1..11)
        )
    );

    my $values;
    if (my $flytipping = $self->body->contacts->search({ category => 'Fly-tipping' })->first) {
        foreach my $field (@{$flytipping->get_extra_fields}) {
            next unless @{$field->{values} || []};
            foreach (@{$field->{values}}) {
                $values->{$field->{code}}{$_->{key}} = $_->{name};
            }
        }
    }

    my $flytipping_lookup = sub {
        my ($report, $field) = @_;
        my $v = $csv->_extra_field($report, $field) // return '';
        return $values->{$field}{$v} || '';
    };

    my $request_lookups = {
        action => { 1 => 'Deliver', '2::1' => 'Collect+Deliver' },
        reason => { 9 => 'Increase capacity', 6 => 'New property', 1 => 'Missing', '4::4' => 'Damaged' },
        type => {
            %$BRENT_CONTAINERS,
            map { $_ . '::' . $_ => $BRENT_CONTAINERS->{$_} } keys %$BRENT_CONTAINERS,
        },
    };

    $csv->csv_extra_data(sub {
        my $report = shift;

        my $id;
        $id = $csv->_extra_field($report, 'Container_Request_Action') || '';
        my $container_req_action = $request_lookups->{action}{$id} || $id;
        $id = $csv->_extra_field($report, 'Container_Request_Container_Type') || '';
        my $container_req_type = $request_lookups->{type}{$id} || $id;
        $id = $csv->_extra_field($report, 'Container_Request_Reason') || '';
        my $container_req_reason = $request_lookups->{reason}{$id} || $id;

        my $data = {
            location_name => $csv->_extra_field($report, 'location_name'),
            $csv->dbi ? (
                street_name => FixMyStreet::Geocode::Address->new($report->{geocode})->parts->{street},
                image_included => $report->{photo} ? 'Y' : 'N',
            ) : (
                street_name => $report->nearest_address_parts->{street},
                name => $report->name || '',
                user_email => $report->user->email || '',
                image_included => $report->photo ? 'Y' : 'N',
                external_id => $report->external_id || '',
            ),
            usrn => $csv->_extra_field($report, 'usrn'),
            uprn => $csv->_extra_field($report, 'uprn'),
            InspectionDate => $csv->_extra_field($report, 'InspectionDate'),
            GradeLitter => $csv->_extra_field($report, 'GradeLitter'),
            GradeDetritus => $csv->_extra_field($report, 'GradeDetritus'),
            GradeGraffiti => $csv->_extra_field($report, 'GradeGraffiti'),
            GradeFlyPosting =>$csv->_extra_field($report, 'GradeFlyPosting'),
            GradeWeeds => $csv->_extra_field($report, 'GradeWeeds'),
            GradeOverall => $csv->_extra_field($report, 'GradeOverall'),
            flytipping_did_you_see => $flytipping_lookup->($report, 'Did_you_see_the_Flytip_take_place?_'),
            flytipping_statement => $flytipping_lookup->($report, 'Are_you_willing_to_be_a_WItness?_'),
            flytipping_quantity => $flytipping_lookup->($report, 'Flytip_Size'),
            flytipping_type => $flytipping_lookup->($report, 'Flytip_Type'),
            container_req_action => $container_req_action,
            container_req_type => $container_req_type,
            container_req_reason => $container_req_reason,
            email_renewal_reminders_opt_in => $csv->_extra_field($report, 'email_renewal_reminders_opt_in'),
            missed_collection_id => $csv->_extra_field($report, 'service_id'),
        };

        my $extra = $csv->_extra_metadata($report);
        %$data = (%$data, map {$_ => $extra->{$_} || ''} grep { $_ =~ /^(item_\d+)$/ } keys %$extra);

        return $data;
    });
}

=head2 open311_config

Sends all photo urls in the Open311 data

=cut

sub open311_config {
    my ($self, $row, $h, $params, $contact) = @_;
    $params->{multi_photos} = 1;
    $params->{upload_files} = 1;
}

=head2 open311_munge_update_params

Updates which are sent over Open311 have 'service_request_id_ext' set
to the id of the update's report

=cut

sub open311_munge_update_params {
    my ($self, $params, $comment, $body) = @_;
    $params->{service_request_id_ext} = $comment->problem->id;
}

=head2 should_skip_sending_update

Do not try and send updates to the ATAK or Symology backends.

=cut

sub should_skip_sending_update {
    my ($self, $update) = @_;

    my $code = $update->problem->contact->email;
    return 1 if $code =~ /^(ATAK|Symology)/;
    return 0;
}


=head2 open311_update_missing_data

=over 4

=cut

sub open311_update_missing_data {
    my ($self, $row, $h, $contact) = @_;

=item * Adds NSGRef from WFS service as app doesn't include road layer for Symology

Reports made via the app probably won't have a NSGRef because we don't
display the road layer. Instead we'll look up the closest asset from the
WFS service at the point we're sending the report over Open311.
We also might need to map one value to another.

=cut

    if ($contact->email =~ /^Symology/) {
        if (!$row->get_extra_field_value('NSGRef')) {
            if (my $ref = $self->lookup_site_code($row, 'usrn')) {
                $row->update_extra_field({ name => 'NSGRef', description => 'NSG Ref', value => $ref });
            }
        }

        my $ref = $row->get_extra_field_value('NSGRef') || '';
        my $cfg = $self->feature('area_code_mapping') || {};
        if ($cfg->{$ref}) {
            $row->update_extra_field({ name => 'NSGRef', description => 'NSG Ref', value => $cfg->{$ref} });
        }

=item * Adds NSGRef from WFS service as app doesn't include road layer for Echo

Same as Symology above, but different attribute name.

=cut

    } elsif ($contact->email =~ /^Echo/) {
        my $type = $contact->get_extra_metadata('type') || '';
        if ($type ne 'waste' && !$row->get_extra_field_value('usrn')) {
            if (my $ref = $self->lookup_site_code($row, 'usrn')) {
                $row->update_extra_field({ name => 'usrn', description => 'USRN', value => $ref });
            }
        }
    }

=item * Adds location name from WFS service for reports in ATAK groups, if missing.

=cut

    my @atak_groups = keys %{$self->group_to_layer};
    my $group = $row->get_extra_metadata('group');
    my $group_is_atak = $group && grep { $_ eq $group } @atak_groups;
    my $contact_location_name_field = $contact->get_extra_field(code => 'location_name');
    my $row_location_name = $row->get_extra_field_value('location_name');

    if ($group_is_atak && $contact_location_name_field && !$row_location_name) {
        if (my $name = $self->lookup_location_name($row)) {
            $row->update_extra_field({ name => 'location_name', description => 'Location name', value => $name });
        }
    }
}

=back

=head2 open311_extra_data_include

=over 4

=cut

sub open311_extra_data_include {
    my ($self, $row, $h, $contact) = @_;

    my $open311_only;

=item * Copies UnitID into the details field for the Drains and gullies category

=cut

    if ($contact->email =~ /^Symology/) {
        if ($contact->groups->[0] eq 'Drains and gullies') {
            if (my $id = $row->get_extra_field_value('UnitID')) {
                my $detail = $row->detail . "\n\nukey: $id";
                $row->detail($detail);
            }
        }
        push @$open311_only, { name => 'report_url', value => $h->{url} };

=item * Adds information for constructing the description on the open311 side.

=cut

    } elsif ($contact->email =~ /^ATAK/) {
        push @$open311_only, { name => 'title', value => $row->title };
        push @$open311_only, { name => 'report_url', value => $h->{url} };
        push @$open311_only, { name => 'detail', value => $row->detail };
        push @$open311_only, { name => 'group', value => $row->get_extra_metadata('group') || '' };
    }

=item * The title field gets pushed to location fields in Echo/Symology, so include closest address

We use {closest_address}->summary as this is geocoder-agnostic.

=cut

    if ($contact->email =~ /^Echo/ || $contact->email =~ /^Symology/) {
        my $title = $row->title;
        if ( $h->{closest_address} ) {
            my $addr = $h->{closest_address}->summary;

            $addr =~ s/, England//;
            $addr =~ s/, United Kingdom$//;

            $title .= '; Nearest calculated address = ' . $addr;
        }

        push @$open311_only, { name => 'title', value => $title };
        push @$open311_only, { name => 'description', value => $row->detail };
    }

    return $open311_only;
}

=back

=head2 open311_extra_data_exclude

Doesn't send UnitID for Drains and gullies category as an extra
field in open311 data. It has been transferred to the details
field by open311_extra_data_include

=cut

sub open311_extra_data_exclude {
    my ($self, $row, $h, $contact) = @_;

    return ['UnitID'] if $contact->groups->[0] eq 'Drains and gullies';
    return [];
}

sub open311_pre_send {
    my ($self, $row, $open311) = @_;
    return 'SKIP' if $row->category eq 'Request new container' && $row->get_extra_field_value('request_referral');
}

=head2 open311_post_send

Restore the original detail field if it was changed by open311_extra_data_include
to put the UnitID in the detail field for sending

=cut

sub open311_post_send {
    my ($self, $row, $h, $sender) = @_;

    if ($row->contact->email =~ /ATAK/ && $row->external_id) {
        $row->update({ state => 'investigating' });
    }

    if ($row->category eq 'Request new container' && $row->get_extra_field_value('request_referral') && !$row->get_extra_metadata('extra_email_sent')) {
        my $emails = $self->feature('open311_email');
        if (my $dest = $emails->{$row->category}) {
            $h->{missing} = "Dear team, you have received this notification because a resident has tried to request a container but the system believes a similar request was recently made against this address. Please assess the request against Echo and then inform the customer of your decision. If authorising the request, please add it to Echo as a container request.\n\n";
            my $sender = FixMyStreet::SendReport::Email->new( to => [ $dest ]);
            $sender->send($row, $h);
            if ($sender->success) {
                $row->update_extra_metadata(extra_email_sent => 1);
            }
        }
    }

    my $error = $sender->error;
    my $db = FixMyStreet::DB->schema->storage;
    $db->txn_do(sub {
        my $row2 = FixMyStreet::DB->resultset('Problem')->search({ id => $row->id }, { for => \'UPDATE' })->single;
        if ($error =~ /Selected reservations expired|Invalid reservation reference/) {
            $self->bulky_refetch_slots($row2);
            $row->discard_changes;
        }
    });
}

=head2 lookup_location_name

Looks up the location name from the WFS service

=cut

sub lookup_location_name {
    my ($self, $report) = @_;

    my $locations = $self->_atak_wfs_query($report);

    # Match the first element like <ms:site_name>King Edward VII Park, Wembley</ms:site_name> and return the value
    if ($locations && $locations =~ /<ms:site_name>(.+?)<\/ms:site_name>/) {
        return $1;
    }
}

=head2 report_validation

Ensure ATAK reports are in ATAK-owned areas

=cut

sub report_validation {
    my ($self, $report, $errors) = @_;

    my $contact = FixMyStreet::DB->resultset('Contact')->find({
        body_id => $self->body->id,
        category => $report->category,
    });

    if ($contact && $contact->email =~ /^ATAK/) {
        my $locations = $self->_atak_wfs_query($report);

        if (index($locations, '<gml:featureMember>') == -1) {
            # Location not found
            $errors->{category} = 'Please select a location in a Brent maintained area';
        }
    }

    return $errors;
}

sub _atak_wfs_query {
    my ($self, $report) = @_;

    my $group = $report->get_extra_metadata('group');
    return unless $group;

    my $asset_layer = $self->_group_to_asset_layer($group);
    return unless $asset_layer;

    my $uri = URI->new('https://tilma.mysociety.org/mapserver/brent');
    $uri->query_form(
        REQUEST => "GetFeature",
        SERVICE => "WFS",
        SRSNAME => "urn:ogc:def:crs:EPSG::27700",
        TYPENAME => $asset_layer,
        VERSION => "1.1.0",
        properties => 'site_name',
    );

    try {
        return $self->_get($self->_wfs_uri($report, $uri));
    } catch {
        # Ignore WFS errors.
        return '';
    };
}

has group_to_layer => (
    is => 'ro',
    default => sub {
        return {
            'Parks and open spaces' => 'Parks_and_Open_Spaces',
            'Allotments' => 'Allotments',
            'Council estates grounds maintenance' => 'Housing',
            'Roadside verges and flower beds' => 'Highway_Verges',
        };
    },
);

sub _group_to_asset_layer {
    my ($self, $group) = @_;

    return $self->group_to_layer->{$group};
}

sub _wfs_uri {
    my ($self, $report, $base_uri) = @_;

    # This fn may be called before cobrand has been set in the
    # reporting flow and local_coords needs it to be set
    $report->cobrand('brent') if !$report->cobrand;

    my ($x, $y) = $report->local_coords;
    my $buffer = 50; # metres
    my ($w, $s, $e, $n) = ($x-$buffer, $y-$buffer, $x+$buffer, $y+$buffer);

    my $filter = "
    <ogc:Filter xmlns:ogc=\"http://www.opengis.net/ogc\">
        <ogc:BBOX>
            <ogc:PropertyName>Shape</ogc:PropertyName>
            <gml:Envelope xmlns:gml='http://www.opengis.net/gml' srsName='EPSG:27700'>
                <gml:lowerCorner>$w $s</gml:lowerCorner>
                <gml:upperCorner>$e $n</gml:upperCorner>
            </gml:Envelope>
        </ogc:BBOX>
    </ogc:Filter>";
    $filter =~ s/\n\s+//g;

    $filter = URI::Escape::uri_escape_utf8($filter);

    return "$base_uri&filter=$filter";
}

# Wrapper around LWP::Simple::get to make mocking in tests easier.
sub _get {
    my ($self, $uri) = @_;

    return get($uri);
}

=head2 prevent_questionnaire_updating_status

Doesn't allow questionnaire responses to change the
status of reports

=cut

sub prevent_questionnaire_updating_status { 1 };

=head2 Staff payments

If a staff member is making a payment, then instead of using SCP, we redirect
to Paye. We also need to check the completed payment against the same source.

=cut

around waste_cc_get_redirect_url => sub {
    my ($orig, $self, $c, $back) = @_;

    if ($c->stash->{is_staff}) {
        my $payment = Integrations::Paye->new({
            config => $self->feature('payment_gateway')
        });

        my $p = $c->stash->{report};
        my $uprn = $p->get_extra_field_value('uprn');

        my $amount = $p->get_extra_field_value( 'pro_rata' );
        unless ($amount) {
            $amount = $p->get_extra_field_value( 'payment' );
        }
        my $admin_fee = $p->get_extra_field_value('admin_fee');

        my $redirect_id = mySociety::AuthToken::random_token();
        $p->set_extra_metadata('redirect_id', $redirect_id);
        $p->update;

        my $backUrl = $c->uri_for_action("/waste/$back", [ $c->stash->{property}{id} ]) . '';
        my $address = $c->stash->{property}{address};
        my @parts = split ',', $address;

        my @items = ({
            amount => $amount,
            reference => $payment->config->{customer_ref},
            description => $p->title,
            lineId => $self->waste_cc_payment_line_item_ref($p),
        });
        if ($admin_fee) {
            push @items, {
                amount => $admin_fee,
                reference => $payment->config->{customer_ref_admin_fee},
                description => 'Admin fee',
                lineId => $self->waste_cc_payment_admin_fee_line_item_ref($p),
            };
        }
        my $result = $payment->pay({
            returnUrl => $c->uri_for('pay_complete', $p->id, $redirect_id ) . '',
            backUrl => $backUrl,
            ref => $self->waste_cc_payment_sale_ref($p),
            request_id => $p->id,
            description => $p->title,
            name => $p->name,
            email => $p->user->email,
            uprn => $uprn,
            address1 => shift @parts,
            address2 => shift @parts,
            country => 'UK',
            postcode => pop @parts,
            items => \@items,
            staff => $c->stash->{staff_payments_allowed} eq 'cnp',
        });

        if ( $result ) {
            $c->stash->{xml} = $result;

            # GET back
            # requestId - should match above
            # apnReference - transaction Ref, used later for query
            # transactionState - InProgress
            # invokeResult/status - Success/...
            # invokeResult/redirectUrl - what is says
            # invokeResult/errorDetails - what it says
            if ( $result->{transactionState} eq 'InProgress' &&
                 $result->{invokeResult}->{status} eq 'Success' ) {

                 $p->set_extra_metadata('apnReference', $result->{apnReference});
                 $p->update;

                 my $redirect = $result->{invokeResult}->{redirectUrl};
                 $redirect .= "?apnReference=$result->{apnReference}";
                 return $redirect;
             } else {
                 # XXX - should this do more?
                my $error = $result->{invokeResult}->{status};
                $c->stash->{error} = $error;
                return undef;
             }
         } else {
            return undef;
        }
        return;
    }

    return $self->$orig($c, $back);
};

around garden_cc_check_payment_status => sub {
    my ($orig, $self, $c, $p) = @_;

    if (my $apn = $p->get_extra_metadata('apnReference')) {
        my $payment = Integrations::Paye->new({
            config => $self->feature('payment_gateway')
        });

        my $resp = $payment->query({
            request_id => $p->id,
            apnReference => $apn,
        });

        if ($resp->{transactionState} eq 'Complete') {
            if ($resp->{paymentResult}->{status} eq 'Success') {
                my $auth_details
                    = $resp->{paymentResult}{paymentDetails}{authDetails};
                $p->update_extra_metadata(
                    authCode => $auth_details->{authCode},
                    continuousAuditNumber => $resp->{paymentResult}{paymentDetails}{payments}{paymentSummary}{continuousAuditNumber},
                );
                $p->update_extra_field({ name => 'payment_method', value => 'csc' });
                $p->update;

                my $ref = $auth_details->{uniqueAuthId};
                return $ref;
            } else {
                $c->stash->{error} = $resp->{paymentResult}->{status};
                return undef;
            }
        } else {
            $c->stash->{error} = $resp->{transactionState};
            return undef;
        }
    }

    return $self->$orig($c, $p);
};

=head2 waste_check_staff_payment_permissions

Staff can make payments via a PAYE endpoint.

=cut

sub waste_check_staff_payment_permissions {
    my $self = shift;
    my $c = $self->{c};
    return unless $c->stash->{is_staff};
    $c->stash->{staff_payments_allowed} = 'paye-api';
}

=head2 waste_event_state_map

State map for Echo states - not actually waste only as Echo
used for FMS integration for Brent

=cut

sub waste_event_state_map {
    return {
        New => { New => 'confirmed' },
        Pending => {
            Unallocated => 'action scheduled',
            Accepted => 'action scheduled',
            'Allocated to Crew' => 'in progress',
            'Allocated to EM' => 'investigating',
            'Replacement Bin Required' => 'action scheduled',
        },
        Closed => {
            Closed => 'fixed - council',
            Completed => 'fixed - council',
            'Not Completed' => 'unable to fix',
            'Partially Completed' => 'closed',
            'No Repair Required' => 'unable to fix',
        },
        Cancelled => {
            Rejected => 'closed',
        },
    };
}

=head2 waste_on_the_day_criteria

If it's before 10pm on the day of collection, treat an Outstanding/Allocated
task as if it's the next collection and in progress, and do not allow missed
collection reporting unless it's already been completed.

=cut

sub waste_on_the_day_criteria {
    my ($self, $completed, $state, $now, $row) = @_;

    return unless $now->hour < 22;
    if ($state eq 'Outstanding' || $state eq 'Allocated') {
        $row->{next} = $row->{last};
        $row->{next}{state} = 'In progress';
        delete $row->{last};
    }
    if (!$completed) {
        $row->{report_allowed} = 0;
    }
}

sub waste_containers { $BRENT_CONTAINERS }

sub waste_service_to_containers {
    return (
        262 => [ 16 ],
        265 => [ 6 ],
        269 => [ 8 ],
        316 => [ 11 ],
        317 => [ 13 ],
        807 => [ 46 ],
    );
}

sub waste_quantity_max {
    return (
        262 => 1,
        265 => 1,
        269 => 1,
        316 => 1,
        317 => 5,
        807 => 1,
    );
}

sub waste_bulky_missed_blocked_codes {
    return {
        # Not Completed
        18491 => {
            all => 'the collection could not be completed',
        },
    };
}

=head2 garden_subscription_email_renew_reminder_opt_in

Gives users the option to opt-in or out of a reminder email for renewal
when they first subscribe or renew.

=cut

sub garden_subscription_email_renew_reminder_opt_in { 1 }

sub garden_collection_time { '6:30am' }

sub garden_echo_container_name { 'BRT - Paid Collection Container Quantity' }

sub garden_container_data_extract {
    my ($self, $data) = @_;
    my $garden_bins = $data->{Value};
    # $data->{Value} is a code for the number of bins and corresponds 1:1 (bin), 2:2 (bins) etc,
    # until it gets to 9 when it corresponds to sacks
    if ($garden_bins == '9') {
        my $garden_cost = $self->garden_waste_sacks_cost_pa($garden_bins) / 100;
        return ($garden_bins, 1, $garden_cost);
    } else {
        my $garden_cost = $self->garden_waste_cost_pa($garden_bins) / 100;
        return ($garden_bins, 0, $garden_cost);
    }
}

sub waste_extra_service_info_all_results {
    my ($self, $property, $result) = @_;

    if (!(@$result && grep { $_->{ServiceId} == $self->garden_service_id } @$result)) {
        # No garden collection possible
        $self->{c}->stash->{waste_features}->{garden_disabled} = 1;
    }
}

sub waste_extra_service_info {
    my ($self, $property, @rows) = @_;

    my $calendar_save = {};
    foreach (@rows) {
        next unless $_->{active};
        my $schedules = $_->{Schedules};

        $_->{timeband} = _timeband_for_schedule($schedules->{next});

        # Brent has two overlapping schedules for food
        $schedules->{description} =~ s/other\s*// if $_->{ServiceId} == 316 || $_->{ServiceId} == 263;

        # Check calendar allocation
        if (($_->{ServiceId} == 262 || $_->{ServiceId} == 317 || $_->{ServiceId} == 807) && ($schedules->{description} =~ /every other/ || $schedules->{description} =~ /every \d+(th|st|nd|rd) week/) && $schedules->{next}{schedule}) {
            my $allocation = $schedules->{next}{schedule}{Allocation};
            my $day = lc $allocation->{RoundName};
            $day =~ s/\s+//g;
            my ($week) = $allocation->{RoundGroupName} =~ /Week (\d+)/;
            my $links;
            if ($_->{ServiceId} == 262 || $_->{ServiceId} == 807) {
                if ($week) {
                    $calendar_save->{number} = $week;
                } elsif (($week) = $allocation->{RoundGroupName} =~ /WK(\w)/) {
                    $calendar_save->{letter} = $week;
                };
                if ($calendar_save->{letter} && $calendar_save->{number}) {
                    my $id = sprintf("%s-%s%s", $day, $calendar_save->{letter}, $calendar_save->{number});
                    $links = $self->{c}->cobrand->feature('waste_calendar_links');
                    $self->{c}->stash->{calendar_link} = $links->{$id};
                }
            } elsif ($_->{ServiceId} == 317) {
                my $id = sprintf("%s-%s", $day, $week);
                my $links = $self->{c}->cobrand->feature('ggw_calendar_links');
                $self->{c}->stash->{ggw_calendar_link} = $links->{$id};
            }
        }
    }
}

sub _timeband_for_schedule {
    my $schedule = shift;

    return unless $schedule->{schedule};

    my $parser = DateTime::Format::Strptime->new( pattern => '%H:%M:%S.%3N' );
    if (my $timeband = $schedule->{schedule}->{TimeBand}) {
        return {
            start => $parser->parse_datetime($timeband->{Start}),
            end => $parser->parse_datetime($timeband->{End})
        };
    }
}

sub missed_event_types { {
    2936 => 'request',
    2891 => 'missed',
    2964 => 'bulky',
} }

around bulky_check_missed_collection => sub {
    my ($orig, $self) = (shift, shift);
    $orig->($self, @_);
    if ($self->{c}->stash->{bulky_missed}) {
        foreach (values %{$self->{c}->stash->{bulky_missed}}) {
            $_->{service_name} = 'Small items';
        }
    }
};

sub image_for_unit {
    my ($self, $unit) = @_;
    my $service_id = $unit->{service_id};

    my $base = '/i/waste-containers';
    my $images = {
        262 => svg_container_bin("wheelie", '#767472'),
        265 => svg_container_bin("wheelie", '#767472', '#00A6D2', 1),
        316 => "$base/caddy-green-recycling",
        317 => svg_container_bin("wheelie", '#41B28A'),
        263 => svg_container_bin("communal", '#333333'),
        266 => svg_container_bin("communal", '#00A6D2', undef, 1),
        271 => svg_container_bin("wheelie", '#8B5E3D'),
        267 => svg_container_sack("normal", '#333333'),
        269 => svg_container_sack("normal", '#d8d8d8'),
        807 => "$base/bag-blue",
        bulky => "$base/electricals-batteries-textiles",
    };
    return $images->{$service_id};
}

sub service_name_override {
    my ($self, $service) = @_;

    my %service_name_override = (
        262 => 'Rubbish',
        265 => 'Recycling',
        316 => 'Food waste',
        317 => 'Garden waste',
        263 => 'Communal rubbish',
        266 => 'Communal recycling',
        271 => 'Communal food waste',
        267 => 'Rubbish (black sacks)',
        269 => 'Recycling (clear sacks)',
        807 => 'Paper and cardboard (blue sacks)',
    );

    return $service_name_override{$service->{ServiceId}} || $service->{ServiceName};
}

sub waste_munge_report_data {
    my ($self, $id, $data) = @_;

    my $c = $self->{c};

    my $address = $c->stash->{property}->{address};
    my $service = $c->stash->{services}{$id}{service_name};

    my $cfg = $self->feature('echo');
    my $service_id_missed = $cfg->{bulky_service_id_missed};
    if (!$service && $id == $service_id_missed) {
        $service = 'small items / clinical';
    }

    $data->{title} = "Report missed $service";
    $data->{detail} = "$data->{title}\n\n$address";

    if ($c->get_param('original_booking_id')) {
        if (my $booking_report = FixMyStreet::DB->resultset("Problem")->find({ id => $c->get_param('original_booking_id') })) {
            $c->set_param('Original_Event_ID', $booking_report->external_id);
        }
    }

    $c->set_param('service_id', $id);
}

# Replace the usual checkboxes grouped by service with one radio list

sub waste_request_single_radio_list { 1 }

sub waste_munge_request_form_fields {
    my ($self, $field_list) = @_;

    my @radio_options;
    my %seen;
    for (my $i=0; $i<@$field_list; $i+=2) {
        my ($key, $value) = ($field_list->[$i], $field_list->[$i+1]);
        next unless $key =~ /^container-(\d+)/;
        my $id = $1;
        push @radio_options, {
            value => $id,
            label => $self->{c}->stash->{containers}->{$id},
            disabled => $value->{disabled},
        };
        $seen{$id} = 1;
    }

    @$field_list = (
        "container-choice" => {
            type => 'Select',
            widget => 'RadioGroup',
            label => 'Which container do you need?',
            options => \@radio_options,
            required => 1,
        }
    );
}


=head2 alternative_backend_field_names

Some field names to send for integrations are defined by earlier
integrations, so this can be used to fetch the different
field name for what is essentially the same field

=cut

sub alternative_backend_field_names {
    my ($self, $field) = @_;

    my %alternative_name = (
        'Subscription_End_Date' => 'End_Date',
    );

    return $alternative_name{$field};
}

sub waste_munge_request_data {
    my ($self, $id, $data, $form) = @_;

    my $c = $self->{c};

    for (qw(how_long_lived contamination_reports ordered_previously)) {
        $c->set_param("request_$_", $data->{$_} || '');
    }
    if (request_referral($id, $data)) {
        $c->set_param('request_referral', 1);
    }

    my $address = $c->stash->{property}->{address};
    my $container = $c->stash->{containers}{$id};
    my $reason = $data->{request_reason} || '';
    my $nice_reason = $c->stash->{label_for_field}->($form, 'request_reason', $reason);

    my ($action_id, $reason_id);
    my $type = $id;
    my $quantity = 1;
    if ($reason eq 'damaged') {
        $action_id = '2::1'; # Collect/Deliver
        $reason_id = '4::4'; # Damaged
        $type = $id . '::' . $id;
        $quantity = '1::1';
    } elsif ($reason eq 'missing') {
        $action_id = 1; # Deliver
        $reason_id = 1; # Missing
    } elsif ($reason eq 'new_build') {
        $action_id = 1; # Deliver
        $reason_id = 6; # New Property
    } elsif ($reason eq 'extra') {
        $action_id = 1; # Deliver
        $reason_id = 9; # Increase capacity
    }

    $c->set_param('Container_Request_Action', $action_id);
    $c->set_param('Container_Request_Reason', $reason_id);
    $c->set_param('Container_Request_Container_Type', $type);
    $c->set_param('Container_Request_Quantity', $quantity);

    $data->{title} = "Request new $container";
    $data->{detail} = "Quantity: 1\n\n$address";
    $data->{detail} .= "\n\nReason: $nice_reason" if $nice_reason;

    my $notes;
    $c->set_param('Container_Request_Notes', $notes) if $notes;

    # XXX Share somewhere with reverse?
    my %service_id = (
        16 => 262,
        6 => 265,
        8 => 269,
        11 => 316,
        13 => 317,
        46 => 807,
    );
    $c->set_param('service_id', $service_id{$id});
}

sub request_referral {
    my ($id, $data) = @_;

    # return 1 if ($data->{contamination_reports} || 0) >= 3; # Will be present on missing only
    return 1 if ($data->{how_long_lived} || '') eq '3more'; # Will be present on new build only
    return 1 if $data->{ordered_previously};
}

sub waste_request_form_first_title { 'Which container do you need?' }
sub waste_request_form_first_next {
    my $self = shift;

    return sub {
        my $data = shift;
        my $choice = $data->{"container-choice"};
        return 'request_refuse_call_us' if $choice == 16;
        return 'replacement';
    };
}

# Take the chosen container and munge it into the normal data format
sub waste_munge_request_form_data {
    my ($self, $data) = @_;
    my $container_id = delete $data->{'container-choice'};
    $data->{"container-$container_id"} = 1;
}

=head2 Waste configuration

=over 4

=item * Waste reports do not have email confirmation.

=item * Staff cannot choose the payment method (if there were multiple)

=item * Cheque payments are not an option

=item * Renewals can happen within 90 days so they are available from beginning of Jan

=cut

sub waste_auto_confirm_report { 1 }
sub waste_staff_choose_payment_method { 0 }
sub waste_cheque_payments { 0 }

sub garden_service_id { 317 }
use constant GARDEN_WASTE_PAID_COLLECTION_BIN => 1;
use constant GARDEN_WASTE_PAID_COLLECTION_SACK => 2;
sub garden_service_name { 'Garden waste collection service' }
sub garden_subscription_event_id { 1159 }
sub garden_due_days { 90 }

sub waste_show_garden_modify {
    my ($self, $unit) = @_;
    return $self->{c}->stash->{is_staff};
}

sub waste_cc_payment_line_item_ref {
    my ($self, $p) = @_;
    return "Brent-" . $p->id;
}

sub waste_cc_payment_sale_ref {
    my ($self, $p) = @_;
    return "Brent-" . $p->id;
}

=item * Staff can pick between sacks/bins for garden waste subscription/renewal

=cut

sub waste_garden_subscribe_form_setup {
    my ($self) = @_;
    my $c = $self->{c};
    if ($c->stash->{is_staff}) {
        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Sacks';
    }
}

sub waste_garden_renew_form_setup {
    my ($self) = @_;
    my $c = $self->{c};
    if ($c->stash->{is_staff}) {
        $c->stash->{first_page} = 'sacks_choice';
        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Sacks::Renew';
    }
}

sub waste_munge_enquiry_data {
    my ($self, $data) = @_;

    my $address = $self->{c}->stash->{property}->{address};
    $data->{title} = $data->{category};

    my $detail;
    foreach (sort grep { /^extra_/ } keys %$data) {
        $detail .= "$data->{$_}\n\n";
    }
    $detail .= $address;
    $data->{detail} = $detail;
}

sub waste_cc_payment_admin_fee_line_item_ref {
    my ($self, $p) = @_;
    return "Brent-" . $p->id;
}

sub waste_garden_sub_params {
    my ($self, $data, $type) = @_;
    my $c = $self->{c};

    my $container = $data->{container_choice} || '';
    $container = $container eq 'sack' ? GARDEN_WASTE_PAID_COLLECTION_SACK : GARDEN_WASTE_PAID_COLLECTION_BIN;
    $c->set_param('Paid_Collection_Container_Type', $container);
    $c->set_param('Paid_Collection_Container_Quantity', $data->{bins_wanted});
    $c->set_param('Payment_Value', $data->{cost_pa});
    if ( $data->{new_bins} > 0 && $container != GARDEN_WASTE_PAID_COLLECTION_SACK ) {
        $c->set_param('Container_Type', $container);
        $c->set_param('Container_Quantity', $data->{new_bins});
    }
}

sub waste_garden_mod_params {
    my ($self, $data) = @_;
    my $c = $self->{c};

    $data->{category} = 'Amend Garden Subscription';

    $c->set_param('Additional_Collection_Container_Type', 1);
    $c->set_param('Additional_Collection_Container_Quantity', $data->{new_bins} > 0 ? $data->{new_bins} : '');

    if ($data->{new_bins} > 0) {
        $c->set_param('Container_Type', 1);
        $c->set_param('Container_Quantity', $data->{new_bins});
    }
}

=item * Sacks cost the same as bins

=cut

sub garden_waste_sacks_cost_pa {
    return $_[0]->garden_waste_cost_pa();
}

=item * Garden subscription is half price in October-December.

=cut

sub garden_waste_cost_pa {
    my ($self, $bin_count) = @_;
    $bin_count ||= 1;
    my $per_bin_cost = $self->_get_cost('ggw_cost');
    my $cost = $per_bin_cost * $bin_count;

    my $now = DateTime->now( time_zone => FixMyStreet->local_time_zone );
    if ($now->month =~ /^(10|11|12)$/ ) {
        $cost = $cost/2;
    }

    return $cost;
}

=item * Uses custom text for the title field for new reports.

=cut

sub new_report_title_field_label {
    "Location of the problem"
}

sub new_report_title_field_hint {
    "Exact location, including any landmarks"
}

=item * Staff can apply a fixed discount to the garden subscription cost via a checkbox.

=back

=cut

sub apply_garden_waste_discount {
    my ($self, @charges ) = @_;

    my $discount = $self->{c}->stash->{waste_features}->{ggw_discount_as_percent};
    my $proportion_to_pay = 1 - $discount / 100;
    my @discounted = map { $_ ? $_ * $proportion_to_pay : $_ } @charges;
    return @discounted;
}

sub garden_waste_new_bin_admin_fee { 0 }

sub bulky_collection_time { { hours => 7, minutes => 0 } }
sub bulky_cancellation_cutoff_time { { hours => 23, minutes => 59 } }
sub bulky_cancel_by_update { 1 }
sub bulky_collection_window_days { 28 }
sub bulky_can_refund { 0 }
sub bulky_free_collection_available { 0 }
sub bulky_hide_later_dates { 1 }

sub bulky_allowed_property {
    my ( $self, $property ) = @_;
    return $self->bulky_enabled;
}

sub collection_date {
    my ($self, $p) = @_;
    return $self->_bulky_date_to_dt($p->get_extra_field_value('Collection_Date'));
}

sub _bulky_refund_cutoff_date { }

sub waste_munge_bulky_data {
    my ($self, $data) = @_;

    my $c = $self->{c};
    my ($date, $ref, $expiry) = split(";", $data->{chosen_date});

    my $guid_key = $self->council_url . ":echo:bulky_event_guid:" . $c->stash->{property}->{id};
    $data->{extra_GUID} = $self->{c}->waste_cache_get($guid_key);
    $data->{extra_reservation} = $ref;

    $data->{title} = "Small items collection";
    $data->{detail} = "Address: " . $c->stash->{property}->{address};
    $data->{category} = "Small items collection";
    $data->{extra_Collection_Date} = $date;
    $data->{extra_Exact_Location} = $data->{location};

    my (%types);
    my $max = $self->bulky_items_maximum;
    my $other_item = 'Small electricals: Other item under 30x30x30 cm';
    for (1..$max) {
        if (my $item = $data->{"item_$_"}) {
            if ($item eq $other_item) {
                $item .= ' (' . ($data->{"item_notes_$_"} || '') . ')';
            }
            $types{$item}++;
            if ($item eq 'Tied bag of domestic batteries (min 10 - max 100)') {
                $data->{extra_Batteries} = 1;
            } elsif ($item eq 'Podback Bag') {
                $data->{extra_Coffee_Pods} = 1;
            } elsif ($item eq 'Paint, up to 5 litres capacity (1 x 5 litre tin, 5 x 1 litre tins etc.)'
                || $item eq 'Paint, 1 can, up to 5 litres') {
                $data->{extra_Paint} = 1;
            } elsif ($item eq 'Textiles, up to 60 litres (one black sack / 3 carrier bags)') {
                $data->{extra_Textiles} = 1;
            } else {
                $data->{extra_Small_WEEE} = 1;
            }
        };
    }
    $data->{extra_Notes} = "Collection date: " . $self->bulky_nice_collection_date($date) . "\n";
    $data->{extra_Notes} .= join("\n", map { "$types{$_} x $_" } sort keys %types);
}

sub waste_reconstruct_bulky_data {
    my ($self, $p) = @_;

    my $saved_data = {
        "chosen_date" => $p->get_extra_field_value('Collection_Date'),
        "location" => $p->get_extra_field_value('Exact_Location'),
        "location_photo" => $p->get_extra_metadata("location_photo"),
    };

    my @fields = grep { /^item_\d/ } keys %{$p->get_extra_metadata};
    for my $id (1..@fields) {
        $saved_data->{"item_$id"} = $p->get_extra_metadata("item_$id");
        $saved_data->{"item_notes_$id"} = $p->get_extra_metadata("item_notes_$id");
    }

    $saved_data->{name} = $p->name;
    $saved_data->{email} = $p->user->email;
    $saved_data->{phone} = $p->phone_waste;

    return $saved_data;
}

=item bulky_open_overdue

Returns true if the booking is open the day after the day the collection was due.

=cut

sub bulky_open_overdue {
    my ($self, $event) = @_;

    if ($event->{state} eq 'open' && $self->_bulky_collection_overdue($event)) {
        return 1;
    }
}

sub _bulky_collection_overdue {
    my $collection_due_date = $_[1]->{date};

    $collection_due_date->add(days => 1)->truncate(to => 'day');
    my $today = DateTime->now->set_time_zone($collection_due_date->time_zone);

    return $today > $collection_due_date;
}

sub _barnet_non_street {
    return [
        'Abandoned vehicles',
        'Graffiti',
        'Dog fouling',
        'Overhanging foliage',
    ]
};

sub _harrow_non_street {
    return [
        'Abandoned vehicles',
        'Car parking',
        'Graffiti',
    ]
}

1;
