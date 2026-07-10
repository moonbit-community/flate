///|
/// Outcome of one step of the streaming DEFLATE state machine.
///
/// The engine is runtime-agnostic: it moves bytes between an input view and an
/// output buffer and *suspends* by returning one of these, so any driver — a
/// synchronous loop or an async adapter — can resume it. 
pub(all) enum Status {
  /// End of the DEFLATE stream was reached; the operation is complete.
  Done
  /// Input was exhausted mid-stream; supply more bytes and call again.
  NeedMoreInput
  /// The output buffer filled up; drain it and call again.
  NeedMoreOutput
} derive(Eq, Debug)

///|
/// Requested action for one streaming compression step.
///
/// The action applies after the complete input view has been consumed. If a
/// step reports partial consumption, re-present the remaining suffix with the
/// same action.
pub(all) enum DeflateAction {
  /// Accept input without emitting a control block.
  Continue
  /// Make all input accepted so far available to the decoder while keeping the
  /// DEFLATE stream open.
  SyncFlush
  /// Finish the DEFLATE stream after all input in this view has been accepted.
  Finish
} derive(Eq, Debug)
