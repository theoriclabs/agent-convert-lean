/-!
# Agent-convert requirements reference model

The Jackson-Zave distinction made executable for this project. Requirements
describe desired effects in the problem world. Machine specifications constrain
only shared phenomena controlled by the converter. Domain assumptions bridge
the two, and the adequacy obligation is `D -> S -> R`.

This module is intentionally independent of `Loom` and `LoomConvert`. The
concrete project model lives in `AgentConvert`; implementation evidence lives in
`Proofs` and depends on the product in the correct direction.
-/

namespace AgentConvert.Requirements

inductive Control where
  | environment
  | machine
  deriving Repr, DecidableEq, BEq

inductive Sharing where
  | shared
  | unshared
  deriving Repr, DecidableEq, BEq

structure Phenomenon where
  name : String
  control : Control
  sharing : Sharing
  deriving Repr, DecidableEq, BEq

inductive TimeReference where
  | pastOrPresent
  | future
  deriving Repr, DecidableEq, BEq

/-- Jackson-Zave mood: domain knowledge describes the world indicatively;
requirements describe a desired world optatively. -/
inductive Mood where
  | indicative
  | optative
  deriving Repr, DecidableEq, BEq

/-- The three epistemically distinct statement kinds from the reference model.
Only assertions can be false; definitions and designations establish vocabulary. -/
inductive Statement where
  | designation (term grounding : String)
  | definition (defined asFormula : String)
  | assertion (mood : Mood) (content : String)
  deriving Repr, DecidableEq, BEq

def Statement.mustValidate : Statement -> Bool
  | .assertion _ _ => true
  | .designation _ _ | .definition _ _ => false

def Statement.isDomainKnowledge : Statement -> Bool
  | .assertion .indicative _ => true
  | .assertion .optative _ => false
  | .designation _ _ | .definition _ _ => true

def Statement.isRequirement : Statement -> Bool
  | .assertion .optative _ => true
  | _ => false

/-- A machine clause reads shared inputs and constrains one shared output. -/
structure InterfaceClause where
  id : String
  mentions : List Phenomenon
  constrains : Phenomenon
  timeReference : TimeReference
  behavior : String
  deriving Repr

def InterfaceClause.onlyShared (c : InterfaceClause) : Bool :=
  c.mentions.all (fun p => p.sharing == .shared) && c.constrains.sharing == .shared

def InterfaceClause.onlyMachineControlled (c : InterfaceClause) : Bool :=
  c.constrains.control == .machine

def InterfaceClause.noFutureReference (c : InterfaceClause) : Bool :=
  c.timeReference == .pastOrPresent

/- This checks interface metadata only. `behavior` remains prose, so this is not
an implementation-existence or behavioral-correctness proof. -/
def InterfaceClause.metadataWellFormed (c : InterfaceClause) : Bool :=
  c.onlyShared && c.onlyMachineControlled && c.noFutureReference

/-- The project-level W/D/R/S bundle. `program` is deliberately absent: this is
the requirements problem, not an implementation inventory. -/
structure RequirementsProblem where
  world : List Statement
  domain : List Statement
  requirement : Statement
  specification : List InterfaceClause
  deriving Repr

def RequirementsProblem.wellPosed (problem : RequirementsProblem) : Bool :=
  problem.domain.all Statement.isDomainKnowledge &&
  problem.requirement.isRequirement &&
  problem.specification.all InterfaceClause.metadataWellFormed

/-- Every falsifiable indicative assertion relied on by the reduction. These
are validation obligations against the external world, never Lean proof goals. -/
def RequirementsProblem.validationWorklist
    (problem : RequirementsProblem) : List Statement :=
  problem.domain.filter Statement.mustValidate

inductive Priority where
  | mustPreview
  | mustStable
  | should
  deriving Repr, DecidableEq, BEq

inductive Satisfaction where
  | satisfied
  | externalValidationPending
  | partiallySatisfied
  | unsatisfied
  deriving Repr, DecidableEq, BEq

/-- Catalogue interpretation of an obligation's status and evidence. Pending is
reachable only through explicit positive external evidence; it is not release
readiness and carries no externally asserted truth value. -/
inductive FitObligationAssessment where
  | leanProofRequired
  | candidateValidationPending
  | blocked
  deriving Repr, DecidableEq, BEq

/-- The numbered catalogue contains both problem-world outcomes and constraints
on the product chosen to realize them. Only the former are Jackson-Zave `R`;
the latter must trace to an implementable interface clause in `S`. -/
inductive RequirementLevel where
  | problemWorldOutcome
  | productConstraint
  deriving Repr, DecidableEq, BEq

inductive EvidenceKind where
  | theorem
  | decidePin
  | fixtureTest
  | differentialTest
  | corpusValidation
  | harnessValidation
  | humanValidation
  | buildValidation
  | review
  deriving Repr, DecidableEq, BEq

inductive EvidencePolarity where
  | supports
  | contradicts
  deriving Repr, DecidableEq, BEq

/-- What a piece of evidence is evidence *for*. Method (`EvidenceKind`) and
claim role are intentionally separate: an adequacy theorem is not an
implementation-refinement theorem, and neither proves a domain bridge. -/
inductive EvidenceRole where
  | adequacyArgument
  | implementationRefinement
  | domainValidation
  | releaseProcess
  | gapRecord
  deriving Repr, DecidableEq, BEq

inductive AssumptionStatus where
  | validated
  | conditional
  | unvalidated
  deriving Repr, DecidableEq, BEq

structure Stakeholder where
  id : String
  name : String
  interest : String
  deriving Repr

structure Designation where
  term : String
  grounding : String
  deriving Repr

structure DomainAssumption where
  id : String
  statement : String
  falsifier : String
  validation : String
  status : AssumptionStatus
  deriving Repr

/-- A rule for how evidence is interpreted. Unlike a domain assumption, a
validation policy is chosen by the project and therefore does not belong in D. -/
structure ValidationPolicy where
  id : String
  statement : String
  rationale : String
  deriving Repr

inductive RequirementId where
  | sourceCoverage
  | structuralIntegrity
  | semanticFidelity
  | noSilentLoss
  | wireCompatibility
  | sidechainSafety
  | provenanceHonesty
  | failureContract
  | determinism
  | portableBuild
  | schemaEvolution
  | performance
  | transcriptReadability
  | crossHarnessContinuation
  | maximalPreservation
  | semanticAuthority
  | toolLifecycleFidelity
  | contextIsolation
  deriving Repr, DecidableEq, BEq

def RequirementId.all : List RequirementId := [
  .sourceCoverage,
  .structuralIntegrity,
  .semanticFidelity,
  .noSilentLoss,
  .wireCompatibility,
  .sidechainSafety,
  .provenanceHonesty,
  .failureContract,
  .determinism,
  .portableBuild,
  .schemaEvolution,
  .performance,
  .transcriptReadability,
  .crossHarnessContinuation,
  .maximalPreservation,
  .semanticAuthority,
  .toolLifecycleFidelity,
  .contextIsolation
]

def RequirementId.code : RequirementId -> String
  | .sourceCoverage => "R-001"
  | .structuralIntegrity => "R-002"
  | .semanticFidelity => "R-003"
  | .noSilentLoss => "R-004"
  | .wireCompatibility => "R-005"
  | .sidechainSafety => "R-006"
  | .provenanceHonesty => "R-007"
  | .failureContract => "R-008"
  | .determinism => "R-009"
  | .portableBuild => "R-010"
  | .schemaEvolution => "R-011"
  | .performance => "R-012"
  | .transcriptReadability => "R-013"
  | .crossHarnessContinuation => "R-014"
  | .maximalPreservation => "R-015"
  | .semanticAuthority => "R-016"
  | .toolLifecycleFidelity => "R-017"
  | .contextIsolation => "R-018"

/-- Reference preview scope, kept outside the concrete catalogue/status module.
The cross-check catches accidental priority drift; like every source-level
manifest, it is not a defense against a malicious coordinated source edit. -/
def RequirementId.previewScopeManifest : List RequirementId := [
  .sourceCoverage,
  .structuralIntegrity,
  .semanticFidelity,
  .wireCompatibility,
  .sidechainSafety,
  .failureContract,
  .portableBuild,
  .transcriptReadability,
  .crossHarnessContinuation,
  .semanticAuthority,
  .toolLifecycleFidelity,
  .contextIsolation
]

/-- Expected priority for every requirement identifier. This independent
reference function makes the exact preview set and all non-preview priorities
checkable against the concrete records. -/
def RequirementId.expectedPriority : RequirementId -> Priority
  | .sourceCoverage
  | .structuralIntegrity
  | .semanticFidelity
  | .wireCompatibility
  | .sidechainSafety
  | .failureContract
  | .portableBuild
  | .transcriptReadability
  | .crossHarnessContinuation
  | .semanticAuthority
  | .toolLifecycleFidelity
  | .contextIsolation => .mustPreview
  | .noSilentLoss
  | .provenanceHonesty
  | .determinism
  | .schemaEvolution
  | .performance
  | .maximalPreservation => .mustStable

/-- A problem-world outcome stated by a stakeholder before decomposition into
machine-facing requirements. Keeping this link explicit prevents a complete
self-declared catalogue from omitting the user's actual goals. -/
structure StakeholderGoal where
  id : String
  stakeholder : String
  statement : String
  requirements : List RequirementId
  deriving Repr

structure RequirementRecord where
  id : RequirementId
  title : String
  statement : String
  rationale : String
  fitCriterion : String
  priority : Priority
  level : RequirementLevel := .problemWorldOutcome
  deriving Repr

structure Evidence where
  id : String
  kind : EvidenceKind
  roles : List EvidenceRole
  claim : String
  locator : String
  polarity : EvidencePolarity := .supports
  deriving Repr, DecidableEq, BEq

/-- The pure model classifies what kind of evidence is still required. Neither
case is a satisfaction result, and neither accepts caller-provided truth data. -/
inductive EvidenceQualification where
  | leanProofRequired
  | candidateValidationRequired
  | ineligible
  deriving Repr, DecidableEq, BEq

/-- A pure-model work item naming a claim that must be bound to a Lean proof.
The strings identify the obligation but do not discharge it. -/
structure LeanEvidenceObligation where
  evidenceId : String
  kind : EvidenceKind
  claim : String
  locator : String
  deriving Repr, DecidableEq, BEq

/-- A proof-bearing binding for a particular evidence identifier and
proposition. Downstream modules can construct this only by supplying `proof`;
the catalogue never converts a claim or locator string into this value. -/
structure LeanEvidenceBinding (evidenceId : String) (claim : Prop) : Prop where
  proof : claim

/-- A closed bundle verifies every proposition in an evidence-key family. The
key-to-proposition interpretation belongs in the downstream module that imports
the implementation facts. -/
structure VerifiedEvidenceBundle (Key : Type) (claim : Key -> Prop) : Prop where
  verify : (key : Key) -> claim key

/-- A claim the pure model asks release tooling to validate against an immutable
candidate. There is deliberately no `validated` field and no result type that
feeds pure readiness: candidate binding, retained-byte hashing, and real-world
claim adjudication happen outside this model. -/
structure ExternalValidationObligation where
  evidenceId : String
  kind : EvidenceKind
  roles : List EvidenceRole
  claim : String
  locator : String
  deriving Repr, DecidableEq, BEq

/-- Result space for the pure side of a release decision. There is intentionally
no `ready` constructor: after catalogue checks pass, release tooling must make a
separate decision using facts unavailable to Lean. -/
inductive PureReadinessAssessment where
  | catalogueBlocked
  | externalDecisionRequired
  deriving Repr, DecidableEq, BEq

/-- One independently falsifiable part of a requirement's fit criterion.
Readiness is computed from these obligations; `Trace.status` is a summary that
must agree with them, not an authority by itself. -/
structure FitObligation where
  id : String
  requirement : RequirementId
  statement : String
  evidence : List String
  status : Satisfaction
  deriving Repr

structure Trace where
  requirement : RequirementId
  clauses : List String
  evidence : List String
  status : Satisfaction
  gap : Option String := none
  deriving Repr

/-- A conversion cannot simultaneously be modeled as successful output and as
a refusal. The payload types force clients to handle the two contracts
separately instead of coordinating independent success/failure booleans. -/
inductive ConversionOutcome (Success Refusal : Type) where
  | success (value : Success)
  | safeRefusal (value : Refusal)
  deriving Repr

namespace ConversionOutcome

def isSuccess {Success Refusal : Type} : ConversionOutcome Success Refusal -> Bool
  | .success _ => true
  | .safeRefusal _ => false

def isSafeRefusal {Success Refusal : Type} : ConversionOutcome Success Refusal -> Bool
  | .success _ => false
  | .safeRefusal _ => true

end ConversionOutcome

/-- Data returned on success. Eligibility and semantic facts are deliberately
absent: they are supplied by the independent conversion model below. -/
structure EmissionObservation where
  artifact : String
  deriving Repr, DecidableEq, BEq

/-- Stable public failure-status classes. The numeric values are product
contract data, not problem-world outcomes. -/
inductive FailureStatusClass where
  | invocationFailure
  | importFailure
  | exportOrValidationFailure
  deriving Repr, DecidableEq, BEq

def FailureStatusClass.exitCode : FailureStatusClass -> Nat
  | .invocationFailure => 1
  | .importFailure => 2
  | .exportOrValidationFailure => 3

/-- Structured diagnostic classes. Keeping this separate from status prevents a
generic non-zero result from masquerading as the required typed diagnostic. -/
inductive FailureDiagnosticClass where
  | invalidInvocation
  | sourceImportFailure
  | structuralValidationFailure
  | unsupportedTarget
  | destructiveLoss
  | missingTargetPrerequisites
  | invalidTargetPrerequisites
  | exporterFailure
  deriving Repr, DecidableEq, BEq

/-- Closed failure causes across the invocation, import, validation, support,
and exporter stages covered by R-008/S-004. -/
inductive RefusalCause where
  | invalidInvocation
  | sourceImportFailure
  | structuralValidationFailure
  | unsupportedTarget
  | destructiveLoss
  | missingTargetPrerequisites
  | invalidTargetPrerequisites
  | exporterFailure
  deriving Repr, DecidableEq, BEq

def RefusalCause.all : List RefusalCause := [
  .invalidInvocation,
  .sourceImportFailure,
  .structuralValidationFailure,
  .unsupportedTarget,
  .destructiveLoss,
  .missingTargetPrerequisites,
  .invalidTargetPrerequisites,
  .exporterFailure
]

def RefusalCause.expectedStatusClass : RefusalCause -> FailureStatusClass
  | .invalidInvocation => .invocationFailure
  | .sourceImportFailure => .importFailure
  | .structuralValidationFailure
  | .unsupportedTarget
  | .destructiveLoss
  | .missingTargetPrerequisites
  | .invalidTargetPrerequisites
  | .exporterFailure => .exportOrValidationFailure

def RefusalCause.expectedDiagnosticClass :
    RefusalCause -> FailureDiagnosticClass
  | .invalidInvocation => .invalidInvocation
  | .sourceImportFailure => .sourceImportFailure
  | .structuralValidationFailure => .structuralValidationFailure
  | .unsupportedTarget => .unsupportedTarget
  | .destructiveLoss => .destructiveLoss
  | .missingTargetPrerequisites => .missingTargetPrerequisites
  | .invalidTargetPrerequisites => .invalidTargetPrerequisites
  | .exporterFailure => .exporterFailure

/-- Only these causes can apply after importer acceptance and a passed structural
gate. Earlier-stage failures remain modeled by the product failure contract. -/
def RefusalCause.allowedAfterAcceptance : RefusalCause -> Bool
  | .unsupportedTarget
  | .destructiveLoss
  | .missingTargetPrerequisites
  | .invalidTargetPrerequisites
  | .exporterFailure => true
  | .invalidInvocation
  | .sourceImportFailure
  | .structuralValidationFailure => false

abbrev ArtifactBytes := List UInt8

/-- Data observed for a failed invocation. Exact before/after byte snapshots
model preservation and no replacement; `reportedOutputBytes = none` rules out
presenting a stale destination as this invocation's result. -/
structure RefusalObservation where
  cause : RefusalCause
  statusClass : FailureStatusClass
  diagnosticClass : FailureDiagnosticClass
  diagnosticText : String
  destinationBytesBefore : Option ArtifactBytes
  destinationBytesAfter : Option ArtifactBytes
  reportedOutputBytes : Option ArtifactBytes
  deriving Repr, DecidableEq, BEq

abbrev ObservedConversionOutcome :=
  ConversionOutcome EmissionObservation RefusalObservation

/-- Exact machine/product failure contract for one selected cause. -/
def ClassifiedSafeRefusal
    (expectedCause : RefusalCause) (observation : RefusalObservation) : Prop :=
  observation.cause = expectedCause /\
  observation.statusClass = expectedCause.expectedStatusClass /\
  observation.diagnosticClass = expectedCause.expectedDiagnosticClass /\
  observation.diagnosticText.isEmpty = false /\
  observation.destinationBytesAfter = observation.destinationBytesBefore /\
  observation.reportedOutputBytes = none

/-- Generic S/product-boundary situation for R-008. Cause applicability is an
independent premise; the failed invocation supplies only its observation. -/
structure ProductFailureSituation where
  selectedCause : RefusalCause
  causeApplicable : RefusalCause -> Prop
  observation : RefusalObservation

def ProductFailureContract (failure : ProductFailureSituation) : Prop :=
  failure.causeApplicable failure.selectedCause /\
  ClassifiedSafeRefusal failure.selectedCause failure.observation

theorem productFailureContractObservableConsequences
    (failure : ProductFailureSituation)
    (hContract : ProductFailureContract failure) :
    failure.observation.statusClass =
        failure.selectedCause.expectedStatusClass /\
      failure.observation.diagnosticClass =
        failure.selectedCause.expectedDiagnosticClass /\
      failure.observation.destinationBytesAfter =
        failure.observation.destinationBytesBefore /\
      failure.observation.reportedOutputBytes = none :=
  ⟨hContract.2.2.1, hContract.2.2.2.1,
    hContract.2.2.2.2.2.1, hContract.2.2.2.2.2.2⟩

/-- The observed outcome of the selected importer. -/
inductive ImporterOutcome where
  | accepted
  | rejected
  deriving Repr, DecidableEq, BEq

/-- Result of the CLI structural gate after import. `notRun` records importer
rejection rather than pretending that validation passed or failed. -/
inductive StructuralGateOutcome where
  | passed
  | rejected
  | notRun
  deriving Repr, DecidableEq, BEq

/-- Independent support-policy decision for an accepted source. -/
inductive ConversionSupportDecision where
  | successRequired
  | refusalRequired (cause : RefusalCause)
  deriving Repr, DecidableEq, BEq

/-- The concrete implementation returns only outcome data. It cannot return its
own importer eligibility, support policy, semantic checks, or applicability. -/
structure ConversionRunObservation where
  outcome : ObservedConversionOutcome

/-- Independently modeled predicates for successful output. They are not fields
of `EmissionObservation`, so a returned artifact cannot carry proofs of its own
syntax, contract, projection, or loss disposition. -/
structure EmissionCriteria where
  artifactEmitted : EmissionObservation -> Prop
  targetSyntaxValid : EmissionObservation -> Prop
  targetContractValid : EmissionObservation -> Prop
  commonProjectionAgrees : EmissionObservation -> Prop
  lossDispositionComplete : EmissionObservation -> Prop

/-- Abstract world state fixed independently of a concrete result. Shared
machine phenomena are used by S; consumption, meaning, loss, and caller
recognition remain problem-world phenomena used only by D/R. -/
structure ConversionSituation where
  importerOutcome : ImporterOutcome
  structuralGateOutcome : StructuralGateOutcome
  supportDecision : ConversionSupportDecision
  emissionCriteria : EmissionCriteria
  refusalApplicable : RefusalCause -> Prop
  outcome : ObservedConversionOutcome
  targetConsumesArtifact : Prop
  commonMeaningPreserved : Prop
  noSilentLoss : Prop
  refusalRecognized : Prop
  callerConsumesInvocationArtifact : Prop

def ConversionSituation.sourceAccepted (w : ConversionSituation) : Prop :=
  w.importerOutcome = .accepted /\ w.structuralGateOutcome = .passed

def ValidEmission
    (w : ConversionSituation) (observation : EmissionObservation) : Prop :=
  w.emissionCriteria.artifactEmitted observation /\
  w.emissionCriteria.targetSyntaxValid observation /\
  w.emissionCriteria.targetContractValid observation /\
  w.emissionCriteria.commonProjectionAgrees observation /\
  w.emissionCriteria.lossDispositionComplete observation

/-- Typed semantic facets used to designate concrete D/S/R catalogue entries
without importing an implementation. Their interpretations are fixed below. -/
inductive ConversionDomainFacet where
  | targetContract
  | semanticAdequacy
  | lossObservability
  | safeRefusal
  deriving Repr, DecidableEq, BEq

inductive ConversionSpecificationFacet where
  | requiredSuccess
  | refusalApplicability
  | classifiedRefusal
  deriving Repr, DecidableEq, BEq

inductive ConversionRequirementFacet where
  | targetConsumability
  | semanticFidelity
  | noSilentLoss
  | safeRefusal
  deriving Repr, DecidableEq, BEq

def TargetContractBridge (w : ConversionSituation) : Prop :=
  match w.outcome with
  | .success observation =>
      w.emissionCriteria.artifactEmitted observation ->
      w.emissionCriteria.targetSyntaxValid observation ->
      w.emissionCriteria.targetContractValid observation ->
      w.targetConsumesArtifact
  | .safeRefusal _ => True

def SemanticAdequacyBridge (w : ConversionSituation) : Prop :=
  match w.outcome with
  | .success observation =>
      w.emissionCriteria.commonProjectionAgrees observation ->
        w.commonMeaningPreserved
  | .safeRefusal _ => True

def LossObservabilityBridge (w : ConversionSituation) : Prop :=
  match w.outcome with
  | .success observation =>
      w.emissionCriteria.lossDispositionComplete observation -> w.noSilentLoss
  | .safeRefusal _ => True

/-- D bridges an exact machine refusal to caller recognition. It does not
classify status, preserve bytes, or establish applicability; those are S/product
obligations. -/
def SafeRefusalBridge (w : ConversionSituation) : Prop :=
  match w.supportDecision, w.outcome with
  | .refusalRequired expectedCause, .safeRefusal observation =>
      ClassifiedSafeRefusal expectedCause observation ->
        w.refusalRecognized /\ ¬w.callerConsumesInvocationArtifact
  | _, _ => True

def ConversionDomainFacet.interpret
    (facet : ConversionDomainFacet) (w : ConversionSituation) : Prop :=
  match facet with
  | .targetContract => TargetContractBridge w
  | .semanticAdequacy => SemanticAdequacyBridge w
  | .lossObservability => LossObservabilityBridge w
  | .safeRefusal => SafeRefusalBridge w

def ConversionDomain (w : ConversionSituation) : Prop :=
  ConversionDomainFacet.targetContract.interpret w /\
  ConversionDomainFacet.semanticAdequacy.interpret w /\
  ConversionDomainFacet.lossObservability.interpret w /\
  ConversionDomainFacet.safeRefusal.interpret w

def ConversionSpecificationFacet.interpret
    (facet : ConversionSpecificationFacet) (w : ConversionSituation) : Prop :=
  match facet with
  | .requiredSuccess =>
      w.sourceAccepted -> w.supportDecision = .successRequired ->
        ∃ observation,
          w.outcome = .success observation /\ ValidEmission w observation
  | .refusalApplicability =>
      w.sourceAccepted -> ∀ cause,
        w.supportDecision = .refusalRequired cause ->
          cause.allowedAfterAcceptance = true /\ w.refusalApplicable cause
  | .classifiedRefusal =>
      w.sourceAccepted -> ∀ cause,
        w.supportDecision = .refusalRequired cause ->
          ∃ observation,
            w.outcome = .safeRefusal observation /\
              ClassifiedSafeRefusal cause observation

/-- S separately requires an applicable refusal cause and the exact R-008/S-004
status, diagnostic, destination-preservation, and reporting contract. -/
def ConversionSpec (w : ConversionSituation) : Prop :=
  ConversionSpecificationFacet.requiredSuccess.interpret w /\
  ConversionSpecificationFacet.refusalApplicability.interpret w /\
  ConversionSpecificationFacet.classifiedRefusal.interpret w

theorem conversionSpecRequiresSuccess (w : ConversionSituation)
    (hSpec : ConversionSpec w) (hAccepted : w.sourceAccepted)
    (hSupported : w.supportDecision = .successRequired) :
    ∃ observation,
      w.outcome = .success observation /\ ValidEmission w observation :=
  hSpec.1 hAccepted hSupported

theorem conversionSpecRefusalApplicable (w : ConversionSituation)
    (hSpec : ConversionSpec w) (hAccepted : w.sourceAccepted)
    (cause : RefusalCause)
    (hRefusal : w.supportDecision = .refusalRequired cause) :
    cause.allowedAfterAcceptance = true /\ w.refusalApplicable cause :=
  hSpec.2.1 hAccepted cause hRefusal

theorem conversionSpecSuccessRequiredCannotRefuse (w : ConversionSituation)
    (hSpec : ConversionSpec w) (hAccepted : w.sourceAccepted)
    (hSupported : w.supportDecision = .successRequired) :
    ¬∃ refusal, w.outcome = .safeRefusal refusal := by
  obtain ⟨emission, hSuccess, _⟩ :=
    conversionSpecRequiresSuccess w hSpec hAccepted hSupported
  rintro ⟨refusal, hRefusal⟩
  have hImpossible :
      (ConversionOutcome.success emission : ObservedConversionOutcome) =
        .safeRefusal refusal := hSuccess.symm.trans hRefusal
  cases hImpossible

theorem conversionSpecSuccessValid (w : ConversionSituation)
    (hSpec : ConversionSpec w) (hAccepted : w.sourceAccepted)
    (observation : EmissionObservation)
    (hOutcome : w.outcome = .success observation) :
    ValidEmission w observation := by
  cases hSupport : w.supportDecision with
  | successRequired =>
      obtain ⟨actual, hActual, hValid⟩ := hSpec.1 hAccepted hSupport
      have hSame :
          (ConversionOutcome.success observation : ObservedConversionOutcome) =
            .success actual := hOutcome.symm.trans hActual
      cases hSame
      exact hValid
  | refusalRequired cause =>
      obtain ⟨refusal, hActual, _⟩ :=
        hSpec.2.2 hAccepted cause hSupport
      have hImpossible :
          (ConversionOutcome.success observation : ObservedConversionOutcome) =
            .safeRefusal refusal := hOutcome.symm.trans hActual
      cases hImpossible

theorem conversionSpecRefusalClassified (w : ConversionSituation)
    (hSpec : ConversionSpec w) (hAccepted : w.sourceAccepted)
    (observation : RefusalObservation)
    (hOutcome : w.outcome = .safeRefusal observation) :
    ∃ cause, w.supportDecision = .refusalRequired cause /\
      cause.allowedAfterAcceptance = true /\ w.refusalApplicable cause /\
      ClassifiedSafeRefusal cause observation := by
  cases hSupport : w.supportDecision with
  | successRequired =>
      obtain ⟨emission, hActual, _⟩ := hSpec.1 hAccepted hSupport
      have hImpossible :
          (ConversionOutcome.safeRefusal observation : ObservedConversionOutcome) =
            .success emission := hOutcome.symm.trans hActual
      cases hImpossible
  | refusalRequired cause =>
      obtain ⟨hAllowed, hApplicable⟩ :=
        hSpec.2.1 hAccepted cause hSupport
      obtain ⟨actual, hActual, hClassified⟩ :=
        hSpec.2.2 hAccepted cause hSupport
      have hSame :
          (ConversionOutcome.safeRefusal observation : ObservedConversionOutcome) =
            .safeRefusal actual := hOutcome.symm.trans hActual
      cases hSame
      exact ⟨cause, rfl, hAllowed, hApplicable, hClassified⟩

def ConversionRequirementFacet.interpret
    (facet : ConversionRequirementFacet) (w : ConversionSituation) : Prop :=
  match facet with
  | .targetConsumability =>
      w.sourceAccepted -> ∀ observation,
        w.outcome = .success observation -> w.targetConsumesArtifact
  | .semanticFidelity =>
      w.sourceAccepted -> ∀ observation,
        w.outcome = .success observation -> w.commonMeaningPreserved
  | .noSilentLoss =>
      w.sourceAccepted -> ∀ observation,
        w.outcome = .success observation -> w.noSilentLoss
  | .safeRefusal =>
      w.sourceAccepted -> ∀ observation,
        w.outcome = .safeRefusal observation ->
          w.refusalRecognized /\ ¬w.callerConsumesInvocationArtifact

/-- The safe-refusal conjunct is the top-level problem-world outcome, not the
numbered product constraint R-008. -/
def ConversionRequirement (w : ConversionSituation) : Prop :=
  ConversionRequirementFacet.targetConsumability.interpret w /\
  ConversionRequirementFacet.semanticFidelity.interpret w /\
  ConversionRequirementFacet.noSilentLoss.interpret w /\
  ConversionRequirementFacet.safeRefusal.interpret w

theorem conversionAdequacy (w : ConversionSituation) :
    ConversionDomain w -> ConversionSpec w -> ConversionRequirement w := by
  intro hDomain hSpec
  rcases hDomain with ⟨hTarget, hSemantic, hLoss, hRefusal⟩
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro hAccepted observation hOutcome
    rcases conversionSpecSuccessValid w hSpec hAccepted observation hOutcome with
      ⟨hEmitted, hSyntax, hContract, _, _⟩
    have hTarget' :
        w.emissionCriteria.artifactEmitted observation ->
          w.emissionCriteria.targetSyntaxValid observation ->
          w.emissionCriteria.targetContractValid observation ->
          w.targetConsumesArtifact := by
      simpa [ConversionDomainFacet.interpret, TargetContractBridge, hOutcome]
        using hTarget
    exact hTarget' hEmitted hSyntax hContract
  · intro hAccepted observation hOutcome
    have hMachine :=
      conversionSpecSuccessValid w hSpec hAccepted observation hOutcome
    have hSemantic' :
        w.emissionCriteria.commonProjectionAgrees observation ->
          w.commonMeaningPreserved := by
      simpa [ConversionDomainFacet.interpret, SemanticAdequacyBridge, hOutcome]
        using hSemantic
    exact hSemantic' hMachine.2.2.2.1
  · intro hAccepted observation hOutcome
    have hMachine :=
      conversionSpecSuccessValid w hSpec hAccepted observation hOutcome
    have hLoss' :
        w.emissionCriteria.lossDispositionComplete observation ->
          w.noSilentLoss := by
      simpa [ConversionDomainFacet.interpret, LossObservabilityBridge, hOutcome]
        using hLoss
    exact hLoss' hMachine.2.2.2.2
  · intro hAccepted observation hOutcome
    obtain ⟨cause, hSupport, _, _, hClassified⟩ :=
      conversionSpecRefusalClassified w hSpec hAccepted observation hOutcome
    have hRefusal' :
        ClassifiedSafeRefusal cause observation ->
          w.refusalRecognized /\ ¬w.callerConsumesInvocationArtifact := by
      simpa [ConversionDomainFacet.interpret, SafeRefusalBridge, hSupport,
        hOutcome] using hRefusal
    exact hRefusal' hClassified

/-- Pointwise agreement alone is named explicitly because it remains vacuous on
a model that rejects every input. Full refinement adds success coverage below. -/
def PointwiseImplementationSatisfiesConversionSpec {Input : Type}
    (run : Input -> ConversionRunObservation)
    (model : Input -> ConversionSituation) : Prop :=
  ∀ input,
    (model input).outcome = (run input).outcome /\ ConversionSpec (model input)

/-- A claimed converter refinement must exhibit at least one independently
accepted, success-required input whose returned artifact satisfies the
independent emission criteria. -/
def ConversionRefinementSuccessCoverage {Input : Type}
    (run : Input -> ConversionRunObservation)
    (model : Input -> ConversionSituation) : Prop :=
  ∃ input observation,
    (model input).sourceAccepted /\
    (model input).supportDecision = .successRequired /\
    (run input).outcome = .success observation /\
    ValidEmission (model input) observation

/-- Full abstract S refinement. The implementation contributes only outcome
data; the independent model contributes eligibility, support, semantic checks,
and refusal applicability. It proves no D bridge. -/
def ImplementationRefinesConversionSpec {Input : Type}
    (run : Input -> ConversionRunObservation)
    (model : Input -> ConversionSituation) : Prop :=
  PointwiseImplementationSatisfiesConversionSpec run model /\
  ConversionRefinementSuccessCoverage run model

theorem refinementHasSuccessfulSource {Input : Type}
    (run : Input -> ConversionRunObservation)
    (model : Input -> ConversionSituation)
    (hRefines : ImplementationRefinesConversionSpec run model) :
    ∃ input observation,
      (model input).sourceAccepted /\
      (model input).supportDecision = .successRequired /\
      (run input).outcome = .success observation /\
      ValidEmission (model input) observation :=
  hRefines.2

private def noEmissionCriteria : EmissionCriteria := {
  artifactEmitted := fun _ => False
  targetSyntaxValid := fun _ => False
  targetContractValid := fun _ => False
  commonProjectionAgrees := fun _ => False
  lossDispositionComplete := fun _ => False
}

private def forgedSuccessRun (_ : Unit) : ConversionRunObservation := {
  outcome := .success { artifact := "forged" }
}

private def forgedSuccessModel (_ : Unit) : ConversionSituation := {
  importerOutcome := .accepted
  structuralGateOutcome := .passed
  supportDecision := .successRequired
  emissionCriteria := noEmissionCriteria
  refusalApplicable := fun _ => False
  outcome := (forgedSuccessRun ()).outcome
  targetConsumesArtifact := False
  commonMeaningPreserved := False
  noSilentLoss := False
  refusalRecognized := False
  callerConsumesInvocationArtifact := False
}

/-- Returned success data cannot establish its own semantic eligibility. -/
example :
    ¬ImplementationRefinesConversionSpec forgedSuccessRun forgedSuccessModel := by
  intro hRefines
  have hSpec := (hRefines.1 ()).2
  obtain ⟨observation, _, hValid⟩ :=
    conversionSpecRequiresSuccess (forgedSuccessModel ()) hSpec
      (by simp [forgedSuccessModel, ConversionSituation.sourceAccepted]) rfl
  exact hValid.1

private def refusalFixture : RefusalObservation := {
  cause := .destructiveLoss
  statusClass := .exportOrValidationFailure
  diagnosticClass := .destructiveLoss
  diagnosticText := "destructive loss"
  destinationBytesBefore := some [1, 2, 3]
  destinationBytesAfter := some [1, 2, 3]
  reportedOutputBytes := none
}

private def inapplicableRefusalRun (_ : Unit) : ConversionRunObservation := {
  outcome := .safeRefusal refusalFixture
}

private def inapplicableRefusalModel (_ : Unit) : ConversionSituation := {
  importerOutcome := .accepted
  structuralGateOutcome := .passed
  supportDecision := .refusalRequired .destructiveLoss
  emissionCriteria := noEmissionCriteria
  refusalApplicable := fun _ => False
  outcome := (inapplicableRefusalRun ()).outcome
  targetConsumesArtifact := False
  commonMeaningPreserved := False
  noSilentLoss := False
  refusalRecognized := False
  callerConsumesInvocationArtifact := False
}

/-- Even an exactly classified refusal cannot discharge S when its cause is not
independently applicable to the selected input. -/
example :
    ¬ImplementationRefinesConversionSpec inapplicableRefusalRun
      inapplicableRefusalModel := by
  intro hRefines
  have hSpec := (hRefines.1 ()).2
  have hApplicable := conversionSpecRefusalApplicable
    (inapplicableRefusalModel ()) hSpec
    (by simp [inapplicableRefusalModel, ConversionSituation.sourceAccepted])
    .destructiveLoss rfl
  exact hApplicable.2

private def rejectAllRun (_ : Unit) : ConversionRunObservation := {
  outcome := .safeRefusal refusalFixture
}

private def rejectAllModel (_ : Unit) : ConversionSituation := {
  importerOutcome := .rejected
  structuralGateOutcome := .notRun
  supportDecision := .refusalRequired .destructiveLoss
  emissionCriteria := noEmissionCriteria
  refusalApplicable := fun _ => False
  outcome := (rejectAllRun ()).outcome
  targetConsumesArtifact := False
  commonMeaningPreserved := False
  noSilentLoss := False
  refusalRecognized := False
  callerConsumesInvocationArtifact := False
}

example :
    PointwiseImplementationSatisfiesConversionSpec rejectAllRun rejectAllModel := by
  intro input
  simp [rejectAllRun, rejectAllModel, ConversionSpec,
    ConversionSpecificationFacet.interpret, ConversionSituation.sourceAccepted]

/-- Explicit success coverage prevents a reject-all implementation from using
the conditional S clauses vacuously. -/
example :
    ¬ImplementationRefinesConversionSpec rejectAllRun rejectAllModel := by
  intro hRefines
  obtain ⟨input, _, hAccepted, _⟩ := hRefines.2
  simp [rejectAllModel, ConversionSituation.sourceAccepted] at hAccepted

/-- Domain validation remains a separate predicate from refinement. -/
def DomainBridgesValidatedForImplementation {Input : Type}
    (model : Input -> ConversionSituation) : Prop :=
  ∀ input, ConversionDomain (model input)

theorem implementationAdequacy {Input : Type}
    (run : Input -> ConversionRunObservation)
    (model : Input -> ConversionSituation)
    (hRefines : ImplementationRefinesConversionSpec run model)
    (hDomain : DomainBridgesValidatedForImplementation model) :
    ∀ input, ConversionRequirement (model input) := by
  intro input
  exact conversionAdequacy (model input) (hDomain input) (hRefines.1 input).2

theorem safeFailureAdequacy (w : ConversionSituation)
    (hOutcome : ∃ refusal, w.outcome = .safeRefusal refusal) :
    ConversionDomain w -> ConversionSpec w -> w.sourceAccepted ->
      w.refusalRecognized /\ ¬w.callerConsumesInvocationArtifact := by
  rintro hDomain hSpec hAccepted
  obtain ⟨refusal, hRefusal⟩ := hOutcome
  exact (conversionAdequacy w hDomain hSpec).2.2.2
    hAccepted refusal hRefusal

/-- Narrow, fully machine-local boundary for staged pure pipelines. It says
nothing about target consumption, common meaning, loss completeness, external
domain validation, or destination-file installation. -/
structure MachinePipelineSpec (Input Error Output : Type) where
  gateFailure? : Input -> Option Error
  blocker? : Input -> Option Error
  exporter : Input -> Except Error Output

def MachinePipelineSpec.expectedResult {Input Error Output : Type}
    (spec : MachinePipelineSpec Input Error Output) (input : Input) :
    Except Error Output :=
  match spec.gateFailure? input with
  | some error => .error error
  | none =>
      match spec.blocker? input with
      | some error => .error error
      | none => spec.exporter input

def ImplementationRefinesMachinePipelineSpec {Input Error Output : Type}
    (run : Input -> Except Error Output)
    (spec : MachinePipelineSpec Input Error Output) : Prop :=
  ∀ input, run input = spec.expectedResult input

theorem machinePipelineGateFailureExact {Input Error Output : Type}
    (run : Input -> Except Error Output)
    (spec : MachinePipelineSpec Input Error Output)
    (hRefines : ImplementationRefinesMachinePipelineSpec run spec)
    (input : Input) (error : Error)
    (hGate : spec.gateFailure? input = some error) :
    run input = .error error := by
  simpa [MachinePipelineSpec.expectedResult, hGate] using hRefines input

theorem machinePipelineBlockerFailureExact {Input Error Output : Type}
    (run : Input -> Except Error Output)
    (spec : MachinePipelineSpec Input Error Output)
    (hRefines : ImplementationRefinesMachinePipelineSpec run spec)
    (input : Input) (error : Error)
    (hGate : spec.gateFailure? input = none)
    (hBlocker : spec.blocker? input = some error) :
    run input = .error error := by
  simpa [MachinePipelineSpec.expectedResult, hGate, hBlocker] using hRefines input

theorem machinePipelineExporterResultExact {Input Error Output : Type}
    (run : Input -> Except Error Output)
    (spec : MachinePipelineSpec Input Error Output)
    (hRefines : ImplementationRefinesMachinePipelineSpec run spec)
    (input : Input)
    (hGate : spec.gateFailure? input = none)
    (hBlocker : spec.blocker? input = none) :
    run input = spec.exporter input := by
  simpa [MachinePipelineSpec.expectedResult, hGate, hBlocker] using hRefines input

example :
    (ConversionOutcome.success "artifact" : ConversionOutcome String String).isSuccess =
      true := by
  native_decide

example :
    (ConversionOutcome.safeRefusal "unsupported" :
      ConversionOutcome String String).isSafeRefusal = true := by
  native_decide

example : RequirementId.previewScopeManifest = [
    .sourceCoverage, .structuralIntegrity, .semanticFidelity,
    .wireCompatibility, .sidechainSafety, .failureContract, .portableBuild,
    .transcriptReadability, .crossHarnessContinuation, .semanticAuthority,
    .toolLifecycleFidelity, .contextIsolation] := by
  native_decide

/-- Constructor-by-constructor coverage prevents a new requirement identifier
from being omitted silently from the hand-maintained catalogue census. -/
theorem RequirementId.censusComplete (rid : RequirementId) :
    RequirementId.all.contains rid = true := by
  cases rid <;> native_decide

example : RequirementId.all.eraseDups.length = RequirementId.all.length := by
  native_decide

example :
    (RequirementId.all.filter (fun rid =>
      rid.expectedPriority == .mustPreview)) =
      RequirementId.previewScopeManifest := by
  native_decide

example : RefusalCause.all = [
    .invalidInvocation, .sourceImportFailure, .structuralValidationFailure,
    .unsupportedTarget, .destructiveLoss, .missingTargetPrerequisites,
    .invalidTargetPrerequisites, .exporterFailure] := by
  native_decide

/-- Exhaustiveness makes adding any failure class an explicit model and review
change rather than an untracked extension of the datatype. -/
theorem RefusalCause.censusComplete (cause : RefusalCause) :
    RefusalCause.all.contains cause = true := by
  cases cause <;> native_decide

example : RefusalCause.all.eraseDups.length = RefusalCause.all.length := by
  native_decide

example : FailureStatusClass.invocationFailure.exitCode = 1 /\
    FailureStatusClass.importFailure.exitCode = 2 /\
    FailureStatusClass.exportOrValidationFailure.exitCode = 3 := by
  native_decide

example : ClassifiedSafeRefusal .destructiveLoss refusalFixture := by
  unfold ClassifiedSafeRefusal refusalFixture
  native_decide

def uniqueStrings (xs : List String) : Bool :=
  xs.eraseDups.length == xs.length

def nonEmptyStrings (xs : List String) : Bool :=
  xs.all (fun s => !s.isEmpty)

end AgentConvert.Requirements
