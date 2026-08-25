/// How much of what a step's row says was MEASURED, as opposed to taken on trust.
///
/// This is not how the step ended — that is its verdict, and a step can fail with its standing
/// proven, because a failure the framework measured is still something the framework measured. The
/// two are separate on purpose: a run that read one off the other would report a row nothing looked
/// at as green, which is the exact claim this framework exists not to make.
///
/// **Stamped by the engine, never by the step.** A step returns what it would change; where that
/// answer came from is decided by the code that asked, in `StepExecution`. A field a step filled in
/// itself would be a field a step could get wrong, and the one that got it wrong would be the one
/// whose row somebody was relying on.
enum StepStanding {
  /// The framework measured this row.
  ///
  /// In a test that is the step's own check answering; in a dry run it is the plan the step
  /// produced with the planning ports in place, so every mutation it reached for on the way to the
  /// answer was refused; in a real run it is the postcondition holding after the apply.
  ///
  /// **The reading has to have come back on THIS run.** A step of a shape that can be proven is not
  /// a proven row; a step of that shape whose reading came back is. The three lines above name
  /// which reading that is per mode, and no other reading stands in for it: a real run whose apply
  /// stopped never reached its postcondition, however much its check answered beforehand.
  proven,

  /// Something here was taken on trust, because it could not be measured.
  ///
  /// TWO CASES REACH IT. A step whose whole job is verifying an earlier step, asked in a mode where
  /// that earlier step has not run: its check cannot hold and its plan is what it says it would do
  /// rather than what anything confirmed. And a row whose reading never came back — the check threw
  /// instead of answering, the plan could not be composed, the apply stopped before anything read
  /// what the machine holds now — so the row failed with nothing behind the one thing it would have
  /// been judged on. Reporting either as proven would put the weight of a measurement behind a
  /// claim.
  ///
  /// **It does not say why the reading is missing, and it is not meant to.** A row whose command
  /// was refused before a process started and a row whose command ran and answered with an exit
  /// code that is not zero are both declared, because neither left a reading of the state the row
  /// speaks of. Which of the two happened is in the row's verdict, in the words the failure came
  /// with, and that is the only place it is written.
  declared,

  /// The step did not run, so there is nothing here to have measured.
  ///
  /// A `when:` condition the program declared did not hold on this machine. **Skipped is not
  /// passed**: it is counted apart from the proven rows and never added to them.
  skipped,
}
