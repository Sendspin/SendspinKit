# ClockSyncDiagnostics

Real-time clock synchronization diagnostics for SendspinKit. This tool helps you understand how well your client is synchronized with the Sendspin server's clock.

## What is Clock Synchronization?

Multi-room audio requires all players to render the exact same audio sample at the exact same microsecond. Even a 1-2ms offset between players causes audible echo and phase cancellation issues. To achieve this, SendspinKit uses an NTP-style clock synchronization protocol with drift compensation.

## How It Works

### NTP-Style 4-Way Handshake

Clock synchronization uses a 4-way timestamp exchange:

1. **Client sends** timestamp `t1` (client transmit time)
2. **Server receives** at `t2` (server receive time)
3. **Server replies** at `t3` (server transmit time)
4. **Client receives** at `t4` (client receive time)

From these timestamps we calculate:

- **Round-Trip Time (RTT)**: `(t4 - t1) - (t3 - t2)`
  - Measures total network latency
  - Used to assess sync quality

- **Clock Offset**: `((t2 - t1) + (t3 - t4)) / 2`
  - Difference between server and client clocks
  - Positive = server ahead, negative = server behind

### Drift Compensation

Real-world clocks don't tick at exactly the same rate. A quartz crystal oscillator might run at 48.000 MHz on one device and 48.001 MHz on another. This frequency difference causes clocks to drift apart over time.

SendspinKit uses a Kalman filter approach to track both:

- **Offset**: Current time difference
- **Drift**: Rate of change in offset (μs/μs)

By tracking drift, the system can predict what the offset should be at any moment and correct for clock frequency differences between devices.

## Usage

### Discover servers

```bash
swift run ClockSyncDiagnostics --discover
```

### Connect to a specific server

```bash
swift run ClockSyncDiagnostics --server ws://192.168.1.100:8080
```

### Adjust refresh rate

```bash
swift run ClockSyncDiagnostics --server ws://192.168.1.100:8080 --interval 0.5
```

## Understanding the Metrics

### Clock Offset

The time difference between server and client clocks, measured in milliseconds.

- **< 1ms**: Excellent - ideal for multi-room audio
- **1-5ms**: Good - acceptable for most scenarios
- **> 5ms**: Poor - may cause audible sync issues

A positive offset means the server clock is ahead of the client clock.

### Round-Trip Time (RTT)

Network latency between client and server, measured in milliseconds.

- **< 10ms**: Excellent - enables precise synchronization
- **10-50ms**: Good - workable for most networks
- **> 50ms**: Degraded - limits sync accuracy

Lower RTT improves sync quality because there's less uncertainty in the measurements.

### Drift Rate

Clock frequency difference, measured in microseconds per microsecond (dimensionless).

Typical values:
- **< 50 PPM**: Excellent - most consumer hardware
- **50-100 PPM**: Moderate - Kalman filter compensates
- **> 100 PPM**: High - may indicate hardware issues

PPM (parts per million) = drift × 1,000,000. For example, a drift of 0.000050 μs/μs equals 50 PPM, meaning the clocks diverge by 50 microseconds per second.

### Sync Quality

Overall assessment based on RTT:

- 🟢 **EXCELLENT** (good): RTT < 50ms, sync is stable
- 🟡 **DEGRADED**: RTT 50-100ms, sync quality reduced
- 🔴 **LOST**: No recent sync or RTT > 100ms

## Sample Count

Number of sync samples collected. The Kalman filter needs:

- **1 sample**: Initialize offset
- **2+ samples**: Calculate drift rate
- **3+ samples**: Fully adaptive prediction

More samples improve accuracy as the filter learns the clock characteristics.

## Why Sub-Millisecond Matters

Human hearing is incredibly sensitive to timing:

- **< 1ms**: Imperceptible - perfect sync
- **1-5ms**: Slight "spaciousness" - may enhance or detract
- **5-20ms**: Audible echo - perceived as distinct events
- **> 20ms**: Clear echo - degraded listening experience

For critical listening or cinema applications, aim for sub-millisecond synchronization.

## Technical Notes

### Kalman Filter

The synchronizer uses a simplified Kalman filter with:

- **State**: [offset, drift]
- **Prediction**: offset_pred = offset + drift × Δt
- **Update**: offset += gain × (measured - predicted)
- **Gain**: 0.1 (10% weight to new measurements)

This provides smooth tracking with outlier rejection.

### Time Domains

SendspinKit uses process-relative time (microseconds since process start) rather than wall-clock time. This avoids issues with:

- System clock adjustments (NTP, manual changes)
- Timezone changes
- Leap seconds

The synchronizer maps between server and client process time domains.

## Building

```bash
swift build
```

## Running

```bash
swift run ClockSyncDiagnostics --discover
swift run ClockSyncDiagnostics --server ws://localhost:8080
```
