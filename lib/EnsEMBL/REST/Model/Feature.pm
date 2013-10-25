package EnsEMBL::REST::Model::Feature;

use Moose;
extends 'Catalyst::Model';

use EnsEMBL::REST::EnsemblModel::ExonTranscript;
use EnsEMBL::REST::EnsemblModel::CDS;
use EnsEMBL::REST::EnsemblModel::TranscriptVariation;
use EnsEMBL::REST::EnsemblModel::TranslationSpliceSiteOverlap;
use EnsEMBL::REST::EnsemblModel::TranslationExon;
use EnsEMBL::REST::EnsemblModel::TranslationSlice;
use EnsEMBL::REST::EnsemblModel::TranslationProteinFeature;

use Bio::EnsEMBL::Utils::Scalar qw/wrap_array/;

has 'allowed_features' => ( isa => 'HashRef', is => 'ro', lazy => 1, default => sub {
  return {
    map { $_ => 1 } qw/gene transcript cds exon repeat simple misc variation somatic_variation structural_variation somatic_structural_variation constrained regulatory/
  };
});

has 'allowed_translation_features' => ( isa => 'HashRef', is => 'ro', lazy => 1, default => sub {
  return {
    'transcript_variation'=> 1, 'protein_feature' => 1, 'residue_overlap' => 1, 'translation_exon' => 1, 'somatic_transcript_variation' => 1
  };
});

with 'Catalyst::Component::InstancePerContext';

has 'context' => (is => 'ro');

sub build_per_context_instance {
  my ($self, $c, @args) = @_;
  return $self->new({ context => $c, %$self, @args });
}

sub fetch_features {
  my ($self) = @_;
  
  my $c = $self->context();
  my $is_gff3 = $self->is_content_type($c, 'text/x-gff3');
  
  my $allowed_features = $self->allowed_features();
  my $feature = $c->request->parameters->{feature};
  $c->go('ReturnError', 'custom', ["No feature given. Please specify a feature to retrieve from this service"]) if ! $feature;
  my @features = (ref($feature) eq 'ARRAY') ? @{$feature} : ($feature);
  
  my $slice = $c->stash()->{slice};
  my @final_features;
  foreach my $feature_type (@features) {
    $feature_type = lc($feature_type);
    next if $feature_type eq 'none';
    my $allowed = $allowed_features->{$feature_type};
    $c->go('ReturnError', 'custom', ["The feature type $feature_type is not understood"]) if ! $allowed;
    my $objects = $self->$feature_type($slice);
    if($is_gff3) {
      push(@final_features, @{$objects});
    }
    else {
      push(@final_features, @{$self->to_hash($objects, $feature_type)});
    }
  }
  
  return \@final_features;
}

sub fetch_protein_features {
  my ($self, $translation) = @_;

  my $c = $self->context();
  my $is_gff3 = $self->is_content_type($c, 'text/x-gff3');

  my $feature = $c->request->parameters->{feature};
  my $allowed_features = $self->allowed_translation_features();

  my @final_features;
  $feature = 'protein_feature' if !( defined $feature);
  my @features = (ref($feature) eq 'ARRAY') ? @{$feature} : ($feature);

  if($is_gff3) {
    $c->stash()->{slice} = EnsEMBL::REST::EnsemblModel::TranslationSlice->new(translation => $translation);
  }

  foreach my $feature_type (@features) {
    $feature_type = lc($feature_type);
    my $allowed = $allowed_features->{$feature_type};
    $c->go('ReturnError', 'custom', ["The feature type $feature_type is not understood"]) if ! $allowed;
    my $objects = $self->$feature_type($translation);
    if($is_gff3) {
      push(@final_features, @{$objects});
    }
    else {
      push(@final_features, @{$self->to_hash($objects, $feature_type)});
    }
  }
  return \@final_features;
}

sub fetch_feature {
  my ($self, $id) = @_;
  my $c = $self->context();
  $c->log()->debug('Finding the object');
  my $object = $c->model('Lookup')->find_object_by_stable_id($id);
  my $hash = {};
  if($object) {
    my $hashes = $self->to_hash([$object]);
    $hash = $hashes->[0];
  }
  return $hash;
}

#Have to do this to force JSON encoding to encode numerics as numerics
my @KNOWN_NUMERICS = qw( start end strand );

sub to_hash {
  my ($self, $features, $feature_type) = @_;
  my @hashed;
  foreach my $feature (@{$features}) {
    my $hash = $feature->summary_as_hash();
    foreach my $key (@KNOWN_NUMERICS) {
      my $v = $hash->{$key};
      $hash->{$key} = ($v*1) if defined $v;
    }
    $hash->{feature_type} = $feature_type;
    push(@hashed, $hash);
  }
  return \@hashed;
}

sub gene {
  my ($self, $slice) = @_;
  my $c = $self->context();
  my ($dbtype, $load_transcripts, $source, $biotype) = 
    (undef, undef, $c->request->parameters->{source}, $c->request->parameters->{biotype});
  return $slice->get_all_Genes($self->_get_logic_dbtype(), $load_transcripts, $source, $biotype);
}

sub transcript {
  my ($self, $slice, $load_exons) = @_;
  my $c = $self->context();
  my $biotype = $c->request->parameters->{biotype};
  my $transcripts = $slice->get_all_Transcripts($load_exons, $self->_get_logic_dbtype());
  if($biotype) {
    my %lookup = map { $_, 1 } @{wrap_array($biotype)};
    $transcripts = [ grep { $lookup{$_->biotype()} } @{$transcripts}];
  }
  return $transcripts;
}

sub cds {
  my ($self, $slice, $load_exons) = @_;
  my $transcripts = $self->transcript($slice, 0);
  return EnsEMBL::REST::EnsemblModel::CDS->new_from_Transcripts($transcripts);
}

sub exon {
  my ($self, $slice) = @_;
  my $exons = $slice->get_all_Exons();
  return EnsEMBL::REST::EnsemblModel::ExonTranscript->build_all_from_Exons($exons);
}

sub repeat {
  my ($self, $slice) = @_;
  return $slice->get_all_RepeatFeatures();
}

sub protein_feature {
  my ($self, $translation) = @_;
  my $c = $self->context();
  my $type = $c->request->parameters->{type};
  my $protein_features = $translation->get_all_ProteinFeatures($type);
  return EnsEMBL::REST::EnsemblModel::TranslationProteinFeature->get_from_ProteinFeatures($protein_features, $translation);
}

sub transcript_variation {
  my ($self, $translation) = @_;
  my $c = $self->context();
  my $species = $c->stash->{species};
  my $type = $c->request->parameters->{type};
  my @vfs;
  my $transcript = $translation->transcript();
  my $transcript_variants;
  my $tva = $c->model('Registry')->get_adaptor($species, 'variation', 'TranscriptVariation');
  my $so_terms = $self->_get_SO_terms();
  if (scalar(@{$so_terms}) > 0) {
    $transcript_variants = $tva->fetch_all_by_Transcripts_SO_terms([$transcript], $so_terms);
  }
  else {
    $transcript_variants = $tva->fetch_all_by_Transcripts([$transcript]);
  }
  return $self->_filter_transcript_variation($transcript_variants);
}

sub somatic_transcript_variation {
  my ($self, $translation) = @_;
  my $c = $self->context();
  my $species = $c->stash->{species};
  my $type = $c->request->parameters->{type};
  my @vfs;
  my $transcript = $translation->transcript();
  my $transcript_variants;
  my $tva = $c->model('Registry')->get_adaptor($species, 'variation', 'TranscriptVariation');
  my $so_terms = $self->_get_SO_terms();
  if (scalar(@{$so_terms}) > 0) {
    $transcript_variants = $tva->fetch_all_somatic_by_Transcripts_SO_terms([$transcript], $so_terms);
  } 
  else {
    $transcript_variants = $tva->fetch_all_somatic_by_Transcripts([$transcript]);
  }
  return $self->_filter_transcript_variation($transcript_variants);
}

sub _filter_transcript_variation {
  my ($self, $transcript_variants) = @_;
  my $type = $self->context->request->parameters->{type};
  my @vfs;
  foreach my $tv (@{$transcript_variants}) {
    if ($type && $tv->display_consequence !~ /$type/) { next ; }
    my $vf = $tv->variation_feature;
    my $blessed_vf = EnsEMBL::REST::EnsemblModel::TranscriptVariation->new_from_variation_feature($vf, $tv);
    push(@vfs, $blessed_vf);
  }
  return \@vfs;
}

sub residue_overlap {
  my ($self, $translation) = @_;
  return EnsEMBL::REST::EnsemblModel::TranslationSpliceSiteOverlap->get_by_Translation($translation);
}

sub translation_exon {
  my ($self, $translation) = @_;
  return EnsEMBL::REST::EnsemblModel::TranslationExon->get_by_Translation($translation);
}

sub variation {
  my ($self, $slice) = @_;
  return $slice->get_all_VariationFeatures($self->_get_SO_terms());
}

sub structural_variation {
  my ($self, $slice) = @_;
  my @so_terms = $self->_get_SO_terms();
  my ($source, $include_evidence, $somatic) = (undef)x3;
  my $sv_class = (@so_terms) ? $so_terms[0] : ();
  return $slice->get_all_StructuralVariationFeatures($source, $include_evidence, $somatic, $sv_class);
}

sub somatic_variation {
  my ($self, $slice) = @_;
  my $c = $self->context();
  my $vfa = $c->model('Registry')->get_adaptor($c->stash->{species}, 'variation', 'variationfeature');
  return $vfa->fetch_all_somatic_by_Slice_SO_terms($slice, $self->_get_SO_terms());
}

sub somatic_structural_variation {
  my ($self, $slice) = @_;
  my @so_terms = $self->_get_SO_terms();
  my ($source, $include_evidence, $somatic) = (undef)x3;
  my ($sv_class) = @so_terms;
  return $slice->get_all_somatic_StructuralVariationFeatures($source, $include_evidence, $somatic, $sv_class);
}

sub constrained {
  my ($self, $slice) = @_;
  my $c = $self->context();
  my $species_set = $c->request->parameters->{species_set} || 'mammals';
  my $compara_name = $c->model('Registry')->get_compara_name_for_species($c->stash()->{species});
  my $mlssa = $c->model('Registry')->get_adaptor($compara_name, 'compara', 'MethodLinkSpeciesSet');
  $c->go('ReturnError', 'custom', ["No adaptor found for compara Multi and adaptor MethodLinkSpeciesSet"]) if ! $mlssa;
  my $method_list = $mlssa->fetch_by_method_link_type_species_set_name('GERP_CONSTRAINED_ELEMENT', $species_set);
  my $cea = $c->model('Registry')->get_adaptor($compara_name, 'compara', 'ConstrainedElement');
  $c->go('ReturnError', 'custom', ["No adaptor found for compara Multi and adaptor ConstrainedElement"]) if ! $cea;
  return $cea->fetch_all_by_MethodLinkSpeciesSet_Slice($method_list, $slice);
}

sub regulatory {
  my ($self, $slice) = @_;
  my $c = $self->context();
  my $species = $c->stash->{species};
  my $rfa = $c->model('Registry')->get_adaptor( $species, 'funcgen', 'regulatoryfeature');
  $c->go('ReturnError', 'custom', ["No adaptor found for species $species, object regulatoryfeature and db funcgen"]) if ! $rfa;
  return $rfa->fetch_all_by_Slice($slice);
}

sub simple {
  my ($self, $slice) = @_;
  my $c = $self->context();
  my ($logic_name, $db_type) = $self->_get_logic_dbtype();
  return $slice->get_all_SimpleFeatures($logic_name, undef, $db_type);
}

sub misc {
  my ($self, $slice) = @_;
  my $c = $self->context();
  my $db_type = $c->request->parameters->{db_type};
  my $misc_set = $c->request->parameters->{misc_set} || undef;
  return $slice->get_all_MiscFeatures($misc_set, $db_type);
}

sub _get_SO_terms {
  my ($self) = @_;
  my $c = $self->context();
  my $so_term = $c->request->parameters->{so_term};
  my $terms = (! defined $so_term)  ? [] 
                                    : (ref($so_term) eq 'ARRAY') 
                                    ? $so_term 
                                    : [$so_term];
  my @final_terms;
  foreach my $term (@{$terms}) {
    if($term =~ /^SO\:/) {
      my $ontology_term = $c->model('Lookup')->ontology_accession_to_OntologyTerm($term);
      if(!$ontology_term) {
        $c->go('ReturnError', 'custom', ["The SO accession '${term}' could not be found in our ontology database"]);
      }
      if ($ontology_term->is_obsolete) {
        $c->go('ReturnError', 'custom', ["The SO accession '${term}' is obsolete"]);
      }
      push(@final_terms, $ontology_term->name());
    }
    else {
      push(@final_terms, $term);
    }
  }
  return \@final_terms;
}

sub _get_logic_dbtype {
  my ($self) = @_;
  my $c = $self->context();
  my $logic_name = $c->request->parameters->{logic_name};
  my $db_type = $c->request->parameters->{db_type};
  return ($logic_name, $db_type);
}

with 'EnsEMBL::REST::Role::Content';

__PACKAGE__->meta->make_immutable;

1;
