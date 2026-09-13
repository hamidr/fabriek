## Owns the language, the records and the overview of the product a
## factory works, and checks a design before a builder gets it: the model
## checkers and the prover come with their skills.
{ specialists, skills, ... }:
{
  extends = [ specialists.developer ];
  skills = [
    skills.decision-record
    skills.domain-overview
    skills.formal-modeling
    skills.lean4-proofs
  ];
  prompt = ./PROMPT.md;
}
