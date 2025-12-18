# ErrorRecovery Example

Demonstrates robust reconnection and error handling patterns for SendspinKit clients.

## Overview

This example shows how to build resilient Sendspin clients that can handle:

- Connection failures during initial handshake
- Unexpected disconnections during streaming
- Temporary server unavailability
- Network interruptions and timeouts

## Key Patterns Demonstrated

### 1. Exponential Backoff with Jitter

The example implements exponential backoff to avoid overwhelming a recovering server:

```
delay = min(baseDelay * 2^(attempt-1) * jitter, 60s)
```

Where:
- `baseDelay`: Initial retry delay (default: 1s)
- `attempt`: Current retry attempt number
- `jitter`: Random factor (0.75-1.25) to prevent thundering herd
- Maximum delay is capped at 60 seconds

**Why jitter?** When many clients lose connection simultaneously, synchronized retries can overwhelm the server. Random jitter spreads out reconnection attempts.

### 2. Connection State Machine

The client tracks connection lifecycle through distinct states:

```
disconnected → connecting → connected
     ↓              ↓            ↓
  failed ← reconnecting ← connection_lost
              ↓
           backoff
```

States:
- **disconnected**: Initial state, no connection
- **connecting**: Attempting connection
- **connected**: Successfully connected and ready
- **reconnecting**: Connection lost, preparing retry
- **backoff**: Waiting before retry (exponential delay)
- **failed**: Maximum retries exceeded or non-retryable error

### 3. Error Classification

Different errors require different handling:

**Retryable Errors** (temporary, worth retrying):
- Network timeouts
- Connection refused (server not ready)
- DNS resolution failures
- Temporary unavailability

**Non-Retryable Errors** (permanent, give up):
- Authentication failures
- Protocol version mismatch
- Invalid credentials
- Malformed server URL

The example demonstrates inspecting errors and making retry decisions.

### 4. Circuit Breaker Pattern

Maximum retry limits prevent infinite retry loops:

- `maxRetries = 0`: Unlimited retries (persistent client)
- `maxRetries > 0`: Give up after N attempts (fail-fast)

After max retries, the client enters `failed` state and stops attempting connections.

### 5. Graceful Degradation

When connection cannot be established:
- Client logs detailed error information
- Provides actionable troubleshooting tips
- Exits cleanly with appropriate status code
- Allows operators to investigate root cause

## Usage

### Discover and Connect

```bash
swift run ErrorRecovery --discover
```

Connect with automatic server discovery and default retry settings.

### Connect to Specific Server

```bash
swift run ErrorRecovery --server ws://localhost:8927
```

Connect to a specific server URL.

### Configure Retry Behavior

```bash
swift run ErrorRecovery \
  --server ws://localhost:8927 \
  --max-retries 10 \
  --retry-delay 2.0
```

- `--max-retries 10`: Give up after 10 attempts
- `--retry-delay 2.0`: Start with 2 second base delay

### Unlimited Retries (Default)

```bash
swift run ErrorRecovery \
  --server ws://localhost:8927 \
  --max-retries 0
```

Retry indefinitely until connection succeeds (useful for embedded devices).

## Testing Scenarios

### Scenario 1: Server Not Running

```bash
# Start the example (server is down)
swift run ErrorRecovery --server ws://localhost:8927 --max-retries 5

# Observe:
# - Initial connection failure
# - Exponential backoff progression
# - Error classification logic
# - Eventually gives up after 5 attempts
```

Expected backoff timeline (1s base):
- Attempt 1: Immediate
- Attempt 2: ~1s delay
- Attempt 3: ~2s delay
- Attempt 4: ~4s delay
- Attempt 5: ~8s delay
- Gives up after attempt 5

### Scenario 2: Server Restart

```bash
# Terminal 1: Start client
swift run ErrorRecovery --server ws://localhost:8927

# Terminal 2: Start/stop server repeatedly
sendspin-server start
sleep 10
sendspin-server stop
sleep 5
sendspin-server start

# Observe:
# - Client connects successfully
# - Detects disconnection
# - Automatically reconnects when server comes back
# - Continues streaming after reconnection
```

### Scenario 3: Network Interruption

```bash
# Simulate network issues using firewall rules
# (macOS example)

# Block port 8927
sudo pfctl -e
echo "block drop proto tcp from any to any port 8927" | sudo pfctl -f -

# Client will detect failure and retry

# Restore connectivity
sudo pfctl -d

# Client reconnects automatically
```

### Scenario 4: Rapid Retry Exhaustion

```bash
swift run ErrorRecovery \
  --server ws://invalid:9999 \
  --max-retries 3 \
  --retry-delay 0.5

# Observe:
# - Fast failure progression (0.5s base)
# - Quickly exhausts retry budget
# - Demonstrates fail-fast pattern
```

## Backoff Calculation Examples

With `baseDelay = 1.0s`:

| Attempt | Formula | Min Delay | Max Delay | Avg Delay |
|---------|---------|-----------|-----------|-----------|
| 1 | 1.0 * 2^0 | 0.75s | 1.25s | 1.0s |
| 2 | 1.0 * 2^1 | 1.5s | 2.5s | 2.0s |
| 3 | 1.0 * 2^2 | 3.0s | 5.0s | 4.0s |
| 4 | 1.0 * 2^3 | 6.0s | 10.0s | 8.0s |
| 5 | 1.0 * 2^4 | 12.0s | 20.0s | 16.0s |
| 6 | 1.0 * 2^5 | 24.0s | 40.0s | 32.0s |
| 7+ | capped | 45.0s | 60.0s | 52.5s |

Jitter range: ±25% (multiply by 0.75-1.25)

## Implementation Details

### State Transitions

All state transitions are logged with timestamps:

```
[2025-01-15T10:30:45Z] State: Disconnected → Connecting (attempt 1)
[2025-01-15T10:30:46Z] State: Connecting (attempt 1) → Backoff (attempt 1, 1.2s)
[2025-01-15T10:30:48Z] State: Backoff (attempt 1, 1.2s) → Connecting (attempt 2)
```

### Event Monitoring

While connected, the client monitors and logs:
- Server info and capabilities
- Stream start/stop events
- Metadata updates
- Group membership changes
- Artwork reception
- Server-side errors

### Graceful Shutdown

The example handles `SIGINT` (Ctrl+C) gracefully:
1. Catches signal
2. Stops retry loop
3. Disconnects client cleanly
4. Logs shutdown completion
5. Exits with code 0

## Production Recommendations

### Retry Strategy

- **Client apps**: Use `maxRetries` to fail fast and inform user
- **Background services**: Use unlimited retries with monitoring
- **Embedded devices**: Unlimited retries with health checks

### Base Delay Selection

- **Fast recovery needed**: 0.5-1.0s base delay
- **Server protection**: 2.0-5.0s base delay
- **Rate-limited APIs**: 5.0-10.0s base delay

### Monitoring

In production, emit metrics for:
- Connection attempt count
- Current backoff delay
- Time spent in disconnected state
- Retry exhaustion events
- Error frequency by type

### Circuit Breaker

Consider external circuit breakers for:
- Known server outages (stop trying during maintenance)
- Repeated authentication failures (need user intervention)
- Protocol mismatches (incompatible versions)

## Code Structure

- `ErrorRecovery`: Main command-line interface
- `RecoveryState`: Connection state enumeration
- `ReconnectionManager`: Orchestrates retry logic
- `classifyError()`: Determines retry eligibility
- `calculateBackoff()`: Implements exponential backoff with jitter

## Learning Path

1. **Read the code**: Start with `main.swift` and trace execution flow
2. **Run basic example**: Connect to a server and observe normal operation
3. **Test failure**: Stop the server and watch retry behavior
4. **Experiment with parameters**: Adjust `maxRetries` and `retryDelay`
5. **Simulate scenarios**: Use the test scenarios above
6. **Adapt for your app**: Copy patterns into your application

## Related Examples

- **DiscoveryExample**: Server discovery patterns
- **CLIPlayer**: Basic connection and streaming
- **MultiCodecPlayer**: Format negotiation with error handling

## References

- [Exponential Backoff and Jitter (AWS)](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- [Circuit Breaker Pattern (Martin Fowler)](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Sendspin Protocol Specification](../../README.md)
