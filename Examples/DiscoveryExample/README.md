# DiscoveryExample

A demonstration of mDNS/Bonjour server discovery in SendspinKit.

## What This Demonstrates

This example shows how to discover Sendspin servers on your local network using mDNS (multicast DNS), also known as Bonjour on Apple platforms. It demonstrates:

- **Network Discovery**: Using `SendspinClient.discoverServers()` to find servers
- **Timeout Configuration**: Controlling how long to wait for discovery
- **Server Metadata**: Accessing server name, URL, hostname, port, and TXT record data
- **Command-Line Interface**: Building a clean CLI tool with ArgumentParser
- **Error Handling**: Gracefully handling cases where no servers are found

## How It Works

The Sendspin protocol uses mDNS to advertise servers on the local network. Servers broadcast the `_sendspin._tcp` service type, which allows clients to automatically discover available servers without requiring manual configuration.

When you run this example, it:

1. Initiates an mDNS scan for `_sendspin._tcp` services
2. Waits for the specified timeout period (default: 5 seconds)
3. Collects all discovered server instances
4. Displays their connection details and metadata
5. Exits with code 0 if servers were found, or 1 if none were found

## Building

From this directory:

```bash
swift build
```

## Running

Basic usage:

```bash
swift run DiscoveryExample
```

### Options

- `--timeout <seconds>` or `-t <seconds>`: Set discovery timeout (1-60 seconds, default: 5)
- `--verbose` or `-v`: Show detailed server metadata from TXT records
- `--help` or `-h`: Display help information

### Examples

Quick scan with 2-second timeout:

```bash
swift run DiscoveryExample --timeout 2
```

Verbose output showing all server metadata:

```bash
swift run DiscoveryExample --verbose
```

Extended scan for slower networks:

```bash
swift run DiscoveryExample --timeout 10
```

## Expected Output

### When servers are found:

```
🔍 Discovering Sendspin servers...
⏱️  Timeout: 5 seconds

✅ Found 2 servers:

[1] My Sendspin Server
    URL:      ws://192.168.1.100:8927
    Host:     macbook-pro.local:8927

[2] Office Server
    URL:      ws://192.168.1.101:8927
    Host:     office-mac.local:8927

✨ Discovery complete!
```

### When no servers are found:

```
🔍 Discovering Sendspin servers...
⏱️  Timeout: 5 seconds

❌ No Sendspin servers found on the local network

💡 Tips:
   • Make sure a Sendspin server is running
   • Check that the server is on the same network
   • Verify firewall settings allow mDNS traffic
   • Try increasing the timeout with --timeout
```

### Verbose output:

```bash
swift run DiscoveryExample --verbose
```

```
🔍 Discovering Sendspin servers...
⏱️  Timeout: 5 seconds

✅ Found 1 server:

[1] My Sendspin Server
    URL:      ws://192.168.1.100:8927
    Host:     macbook-pro.local:8927
    Metadata:
      protocol_version: 1.0
      server_version: 0.1.0

✨ Discovery complete!
```

## Exit Codes

- `0`: Success - at least one server was discovered
- `1`: Failure - no servers found or invalid arguments

This makes the tool scriptable:

```bash
if swift run DiscoveryExample --timeout 3; then
    echo "Servers available!"
else
    echo "No servers on network"
fi
```

## Integration with Your Code

Use this pattern in your own Swift applications:

```swift
import SendspinKit

// Discover servers with custom timeout
let servers = await SendspinClient.discoverServers(timeout: .seconds(5))

if servers.isEmpty {
    print("No servers found")
} else {
    // Use the first server
    let server = servers[0]
    print("Connecting to: \(server.name) at \(server.url)")

    // Access server details
    print("Hostname: \(server.hostname)")
    print("Port: \(server.port)")

    // Check metadata
    if let version = server.metadata["server_version"] {
        print("Server version: \(version)")
    }
}
```

## Troubleshooting

**No servers found:**
- Ensure the Sendspin server is running and advertising via mDNS
- Check that both devices are on the same local network
- Some networks (corporate, guest WiFi) block mDNS traffic
- Try a longer timeout for slower networks

**Discovery is slow:**
- mDNS discovery can take a few seconds as it waits for responses
- Network congestion can delay responses
- Multiple network interfaces may slow down discovery

**Firewall issues:**
- mDNS uses UDP port 5353
- Ensure this port is not blocked by your firewall
- On macOS, check System Preferences > Security & Privacy > Firewall
