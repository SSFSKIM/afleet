// Imports only the umbrella product: this package is the evidence that every value a
// downstream module has to build is reachable and constructible from outside ClaudeWire.
import Foundation
import ClaudeWire

let session = SessionID()
let link = WorkspaceLink.diff(DiffRef(repository: URL(fileURLWithPath: "/tmp/r"), path: "a.swift", base: .commitAgainstParent("abc")))
let env = ResolvedEnvironment(variables: ["PATH": "/usr/bin"], shell: "/bin/zsh", capturedAt: Date(), mode: .login)
let home = ConfigHome.derive(from: env)
let origin: ChannelOrigin = .owned(.contended)
let epoch = ProcessEpoch.first.next()
let launch = LaunchConfiguration(binary: URL(fileURLWithPath: "/usr/local/bin/claude"), cwd: URL(fileURLWithPath: "/tmp"), session: .resume(session, fork: false),
                                 model: "opus", permissionMode: .plan, addDirectories: [], worktree: .named("wt"), allowBypass: false, promptSuggestions: true,
                                 settingSources: [.user], strictMCPConfig: false, environment: ChildEnvironmentOptions(forkSubagents: true, automodeDecisionLog: false, questionPreviewFormat: nil))
let initCfg = InitializeConfiguration(supportedDialogKinds: ["refusal_fallback_prompt"], perTaskStopAffordance: true, agentProgressSummaries: true,
                                      sdkMcpServers: ["afleet"], hooks: [.notification: [HookCallbackMatcher(hookCallbackIds: ["afleet.notification"])]])
let policy = InboundPolicy.default(declaredDialogKinds: ["refusal_fallback_prompt"], registeredHookCallbackIDs: ["afleet.notification"])
let server = AfleetMCPServer(serverVersion: ProtocolBaseline.afleetVersion, cwd: URL(fileURLWithPath: "/tmp"), tools: [SendUserFileTool()])
let process = ClaudeProcess(epoch: epoch, launch: launch, environment: env, configHome: home, initialize: initCfg, policy: policy,
                            mcpServer: server, diagnostics: NullDiagnostics(), capture: nil)
let answer: InboundAnswer = .permission(.allow(updatedInput: nil, updatedPermissions: [.setMode(mode: .acceptEdits, destination: .session)], classification: .userTemporary))
let spec = Interrupt(cancelQueued: true)
let input = UserInput(text: "hello", images: [])
let envelope = ShellEnvelope.wrap(command: "ls", stdout: Data(), stderr: Data())
let frame = FrameDecoder.decode(line: Data(#"{"type":"keep_alive"}"#.utf8))
let inbound = InboundRequest(id: RequestID(rawValue: "r"), epoch: epoch, receivedAt: .now, payload: .unknown(subtype: "x", .null), raw: .object([:]))
// SystemInit is still an X3 value a consumer must be able to build; it just no longer rides on the handshake,
// because the engine emits system/init at the start of a turn rather than at startup.
let sysInitData = Data(#"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s","tools":[],"mcp_servers":[],"model":"m","permissionMode":"default","slash_commands":[],"apiKeySource":"none","claude_code_version":"2.1.259","output_style":"default","skills":[],"plugins":[],"uuid":"u"}"#.utf8)
let systemInit = try JSONDecoder().decode(SystemInit.self, from: sysInitData)
let handshake = Handshake(initialize: InitializeResponse(raw: .object([:])), pending: [inbound])
let event: WireEvent = .request(inbound)
let exit: ExitStatus = .code(0, stderrTail: "")
_ = (link, origin, (try? launch.arguments()) ?? [], initCfg.payload(), answer, type(of: spec).subtype, input.frame(uuid: UUID()), envelope, frame, process.events, handshake, systemInit, event, exit, ProcessStatus.launching)
print("ConsumerSmoke: constructed every X2 and X3 value")
