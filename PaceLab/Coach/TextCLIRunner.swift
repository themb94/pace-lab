import Foundation

/// Any CLI as a coach: question (with training state) in, reply text out.
/// Arguments with placeholders {model}, {prompt}, {system}; without {prompt} the question goes via stdin,
/// without {system} the instruction is prepended to the question.
final class TextCLIRunner: CoachRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var current: CLIProcess?
    private var cancelled = false

    func run(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await execute(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [self] _ in
                task.cancel()
                cancel()
            }
        }
    }

    func cancel() {
        let process = lock.withLock { () -> CLIProcess? in
            cancelled = true
            return current
        }
        process?.cancel()
    }

    private func newProcess() -> CLIProcess? {
        lock.withLock {
            guard !cancelled else { return nil }
            let process = CLIProcess()
            current = process
            return process
        }
    }

    private func execute(_ request: CoachRequest,
                         _ continuation: AsyncThrowingStream<CoachEvent, any Error>.Continuation) async throws {
        let engine = request.engine
        guard let executable = CLIResolver.find(engine.command) else {
            throw CoachError.notFound(engine.command.isEmpty ? String(localized: "(no program set)") : engine.command)
        }
        continuation.yield(.started(model: engine.model.isEmpty ? nil : engine.model, servers: []))

        // 1) Preparation, e.g. load the model
        let prepare = ArgumentTemplate.fill(ArgumentTemplate.tokenize(engine.prepareCommand), with: ["model": engine.model])
        if let program = prepare.first {
            guard let prepareExecutable = CLIResolver.find(program) else { throw CoachError.notFound(program) }
            let stepID = "prepare"
            continuation.yield(.toolStarted(id: stepID, name: "prepare",
                                            label: String(localized: "Preparing: \(prepare.joined(separator: " ").prefix(70))")))
            guard let process = newProcess() else { return }
            var collector = CollectingParser()
            let lines = try process.start(prepareExecutable, Array(prepare.dropFirst()), in: request.workingDirectory, input: nil)
            for await line in lines { _ = collector.parse(line) }
            let outcome = await process.waitForExit()
            continuation.yield(.toolFinished(id: stepID, failed: outcome.exitCode != 0))
            if outcome.signaled {
                continuation.yield(.finished(CoachResult(isError: true, message: "Abgebrochen.")))
                return
            }
            if outcome.exitCode != 0 {
                let details = [outcome.stderr, collector.tail].first { !$0.isEmpty } ?? String(localized: "code \(outcome.exitCode)")
                continuation.yield(.finished(CoachResult(isError: true, message: String(localized: "Preparation failed: \(details)"))))
                return
            }
        }

        // 2) The actual request
        let template = engine.arguments
        let promptAsArgument = ArgumentTemplate.uses("prompt", in: template)
        let systemAsArgument = ArgumentTemplate.uses("system", in: template)
        let text = systemAsArgument ? request.prompt : request.systemPrompt + "\n\n" + request.prompt
        let arguments = ArgumentTemplate.fill(ArgumentTemplate.tokenize(template), with: [
            "model": engine.model,
            "prompt": text,
            "system": request.systemPrompt,
        ])
        guard let process = newProcess() else { return }
        var parser = TextOutputParser()
        try await parser.stream(process, executable, arguments, in: request.workingDirectory,
                                input: promptAsArgument ? nil : text, to: continuation)
    }
}

/// Reply text line by line, without terminal control characters.
struct TextOutputParser: OutputParser {
    private var gotText = false

    mutating func parse(_ line: String) -> [CoachEvent] {
        let clean = ANSI.strip(line)
        if !gotText && clean.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        gotText = true
        return [.textDelta(clean + "\n")]
    }

    mutating func finish(_ outcome: CLIProcess.Outcome) -> CoachEvent? {
        if outcome.signaled { return .finished(CoachResult(isError: true, message: "Abgebrochen.")) }
        if outcome.exitCode != 0 {
            let details = outcome.stderr.isEmpty ? String(localized: "The program exited with code \(outcome.exitCode).") : outcome.stderr
            return .finished(CoachResult(isError: true, message: details))
        }
        if !gotText {
            return .finished(CoachResult(isError: true,
                                         message: String(localized: "No reply received.") + (outcome.stderr.isEmpty ? "" : " \(outcome.stderr)")))
        }
        return .finished(CoachResult(isError: false, message: nil))
    }
}

/// Collects only the last lines (for error messages from the preparation).
private struct CollectingParser: OutputParser {
    private(set) var lines: [String] = []

    var tail: String { lines.suffix(3).joined(separator: "\n") }

    mutating func parse(_ line: String) -> [CoachEvent] {
        let clean = ANSI.strip(line).trimmingCharacters(in: .whitespaces)
        if !clean.isEmpty { lines.append(clean) }
        if lines.count > 20 { lines.removeFirst(lines.count - 20) }
        return []
    }

    mutating func finish(_ outcome: CLIProcess.Outcome) -> CoachEvent? { nil }
}
