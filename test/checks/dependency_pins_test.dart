import 'package:ansiwise_checks_tree/audits.dart';

/// dependency-pins — every dependency this package resolves out of git names a release tag.
///
/// ONE DEPENDENCY IS JUDGED HERE, and it is a DEV dependency: the tree half of the check libraries,
/// which this package's own gate runs and nothing it ships reaches. So the reason this check gives
/// elsewhere — that whoever resolves a branch ref gets a different tree under the same name — is
/// not the reason it applies here: resolving this package never resolves its dev dependencies at
/// all.
///
/// THE REASON THAT DOES APPLY IS GATE REPRODUCIBILITY. The tree standing at a release tag IS the
/// release, and .github/workflows/release.yml runs this gate on that tree. A dev dependency at
/// `master` means re-running the gate at a tag months later judges whatever master holds that day,
/// so the tag no longer says what was measured — which is the same thing the pin one level up
/// exists to prevent.
void main() => auditDependencyPins();
