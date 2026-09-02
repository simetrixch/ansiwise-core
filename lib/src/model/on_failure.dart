/// What the run does when a step fails.
///
/// TWO VALUES, AND THERE IS NOTHING ELSE TO DECIDE HERE. Either the rest of the program still makes
/// sense without this step or it does not. There is no point installing an addon into a cluster that
/// never came up; a cluster whose certificate issuer failed still stands, it just cannot issue a
/// certificate.
///
/// WHAT IS NOT A CONTROL DECISION AND SO DOES NOT STAND HERE. How loudly a failure is written down
/// is a LOG LEVEL, not a question about what happens next. Pressed in here it makes the set
/// unreadable: unrelated English words, no one of which implies the others, so the only way to
/// learn the set is to guess wrong and read the refusal.
///
/// A step logs what happened whatever stands here. Nothing in a program file has to say a second
/// time that a failure was serious.
enum OnFailure {
  /// The run ends here. Nothing after this step is attempted.
  exit,

  /// The run goes on.
  ///
  /// The failure is recorded either way — a step that failed said so, and the run's closing line
  /// reports it. What this value decides is only that the run carried on.
  continueRun,
}

/// What a program file writes for each of [OnFailure], and what the record reports back.
///
/// The same word in both, so an operator who wrote one reads the same one afterwards. `continue` is
/// a reserved word in Dart, which is the only reason the enum value beside it is spelled
/// differently; the file and the record use the word a person would.
const Map<String, OnFailure> onFailureWritten = <String, OnFailure>{
  'exit': OnFailure.exit,
  'continue': OnFailure.continueRun,
};

/// The word [policy] is written as, in a program file and in the record.
String writtenFor(OnFailure policy) => switch (policy) {
  OnFailure.exit => 'exit',
  OnFailure.continueRun => 'continue',
};
