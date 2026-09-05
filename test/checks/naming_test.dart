import 'package:ansiwise_checks_tree/audits.dart';

/// naming — the abolished words appear in no name of THIS repository.
///
/// WHAT WAS ABOLISHED IS A PROGRAM NAME, NOT A VERB, and this distinction is the whole check. The
/// names `install.sh` and `setup.sh` are two programs split along a line nobody can name, which is
/// how one of them comes to do five unrelated things. The
/// verbs for our programs are `deploy` and `onboard`, and what is deployed or onboarded is named
/// after itself.
///
/// `install` as the name of what a command DOES is not abolished and must not be reported. A step
/// that runs `apt-get install` is called install_packages.dart because that is the word the software
/// itself uses, and the naming law of this project is to take that word rather than invent one. A
/// check that forbade the substring would rename the step to something that no longer says what it
/// runs — which is the failure this check exists to prevent, arriving from the other side.
///
/// What is scanned is `tool/` and every Dart package of the tree: the gate's own programs sit
/// outside every package here, and a name an operator reads is a name an operator reads wherever the
/// file lives.
void main() => auditNaming();
