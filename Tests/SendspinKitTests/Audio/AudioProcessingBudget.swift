// ABOUTME: Shared failure bound for asynchronous audio test processing.
import Foundation

// This bounds processing waits, not assertions about elapsed audio timing.
let audioProcessingBudgetMilliseconds = 3_000
let audioProcessingBudget = Duration.milliseconds(audioProcessingBudgetMilliseconds)
