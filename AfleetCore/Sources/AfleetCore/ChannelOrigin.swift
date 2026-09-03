public enum ChannelOrigin: Hashable, Sendable {
    case owned(OwnedState)
    case foreignLive(ForeignHost)
    case backgroundJob
    case archived
    public enum OwnedState: Hashable, Sendable { case connecting, ready, dormant, contended }
    public enum ForeignHost: Hashable, Sendable { case usersTerminal, ownTerminalTab }
}
