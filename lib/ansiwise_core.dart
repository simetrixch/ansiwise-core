/// The deployment framework: a typed step engine with three modes, a run record, and a registry
/// mapping the names a program file writes to the classes that implement them.
///
/// It knows nothing about what is being deployed, and a check
/// turns the tree red if it ever does. That is also why it can leave for its own repository later
/// without becoming anything other than a `git mv`.
library;

export 'src/model/record_json.dart';
export 'src/config/loaded_catalogue.dart';
export 'src/config/condition_binding.dart';
export 'src/model/caller_inputs.dart';
export 'src/config/configuration.dart';
export 'src/config/elevation_source.dart';
export 'src/config/program_loader.dart';
export 'src/domain/answers.dart';
export 'src/domain/argument_check.dart';
export 'src/domain/arguments.dart';
export 'src/domain/derivation.dart';
export 'src/domain/value_shape.dart';
export 'src/domain/catalogue.dart';
export 'src/domain/clock.dart';
export 'src/domain/entropy.dart';
export 'src/domain/files.dart';
export 'src/domain/http.dart';
export 'src/domain/machine.dart';
export 'src/domain/measurement.dart';
export 'src/domain/plugin.dart';
export 'src/domain/predicate.dart';
export 'src/domain/program.dart';
export 'src/domain/recorder.dart';
export 'src/domain/registry.dart';
export 'src/domain/resolved_program.dart';
export 'src/domain/run_launcher.dart';
export 'src/domain/run_retention.dart';
export 'src/domain/run_store.dart';
export 'src/domain/shell.dart';
export 'src/domain/step.dart';
export 'src/domain/step_context.dart';
export 'src/domain/logger.dart';
export 'src/infrastructure/channel_socket.dart';
export 'src/infrastructure/detached_launcher.dart';
export 'src/infrastructure/file_recorder.dart';
export 'src/infrastructure/file_run_store.dart';
export 'src/infrastructure/permissions.dart';
export 'src/infrastructure/real_clock.dart';
export 'src/infrastructure/real_entropy.dart';
export 'src/infrastructure/real_files.dart';
export 'src/infrastructure/real_http.dart';
export 'src/infrastructure/real_shell.dart';
export 'src/infrastructure/record_codec.dart';
export 'src/infrastructure/run_directory.dart';
export 'src/infrastructure/run_removal.dart';
export 'src/engine/planning_ports.dart';
export 'src/engine/fingerprint.dart';
export 'src/engine/gate.dart';
export 'src/engine/measurements.dart';
export 'src/engine/predicate_evaluation.dart';
export 'src/engine/program_resolver.dart';
export 'src/engine/recording_ports.dart';
export 'src/engine/redactor.dart';
export 'src/engine/runner.dart';
export 'src/engine/step_execution.dart';
export 'src/engine/point_of_no_return.dart';
export 'src/engine/unwind.dart';
export 'src/util/ipv4.dart';
export 'src/model/check_result.dart';
export 'src/model/failures.dart';
export 'src/model/file_content.dart';
export 'src/model/mode.dart';
export 'src/model/names.dart';
export 'src/model/on_failure.dart';
export 'src/model/removed_runs.dart';
export 'src/model/run_event.dart';
export 'src/model/run_record.dart';
export 'src/model/standings.dart';
export 'src/model/step_plan.dart';
export 'src/model/step_record.dart';
export 'src/model/step_standing.dart';
export 'src/model/verdict.dart';
export 'src/steps/slots.dart';
export 'src/steps/template.dart';
export 'src/steps/command_step.dart';
export 'src/steps/file_step.dart';

export 'src/steps/wait_step.dart';
