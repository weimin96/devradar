import Foundation
import PScanKit

func printUsage() {
    print("Usage: pscan [options]")
    print("")
    print("Options:")
    print("  -a, --all       Show all ports (including system services)")
    print("  -j, --json      Output as JSON")
    print("  -k, --kill PORT Stop the service on a given port")
    print("  -h, --help      Show this help")
    print("")
}

let args = CommandLine.arguments.dropFirst()
let scanner = PortScanner()

var showAll = false
var jsonOutput = false
var killPort: Int?

var argIterator = args.makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "-a", "--all":
        showAll = true
    case "-j", "--json":
        jsonOutput = true
    case "-k", "--kill":
        guard let next = argIterator.next(), let port = Int(next) else {
            print("Error: --kill requires a port number")
            exit(1)
        }
        killPort = port
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        print("Unknown option: \(arg)")
        printUsage()
        exit(1)
    }
}

let ports = scanner.fetchPorts(includeAll: showAll)

// Stop mode
if let killPort {
    guard let target = scanner.fetchPorts(includeAll: true).first(where: { $0.port == killPort }) else {
        print("No process found on port \(killPort)")
        exit(1)
    }

    let targetName = target.serviceName ?? target.containerName ?? target.processName
    let targetDetail = target.containerID != nil ? "container" : "PID \(target.pid)"
    print("Stop \(targetName) (\(targetDetail)) on :\(target.port)? [y/N] ", terminator: "")
    fflush(stdout)

    if let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" {
        do {
            try scanner.stop(target, mode: .terminate)
            print("Stopped.")
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    } else {
        print("Cancelled.")
    }
    exit(0)
}

// JSON output
if jsonOutput {
    let items = ports.map { port -> [String: Any] in
        var dict: [String: Any] = [
            "port": port.port,
            "process": port.processName,
            "pid": port.pid,
        ]
        if let dir = port.directory { dict["directory"] = dir }
        if let name = port.projectName { dict["project"] = name }
        if let serviceName = port.serviceName { dict["service"] = serviceName }
        if let containerID = port.containerID { dict["containerId"] = containerID }
        if let containerName = port.containerName { dict["container"] = containerName }
        if let composeProject = port.composeProject { dict["composeProject"] = composeProject }
        if let composeService = port.composeService { dict["composeService"] = composeService }
        dict["runtime"] = port.runtimeName
        if let command = port.command { dict["command"] = command }
        if let executable = port.executable { dict["executable"] = executable }
        if let cpuPercent = port.cpuPercent { dict["cpuPercent"] = cpuPercent }
        if let memoryBytes = port.memoryBytes { dict["memoryBytes"] = memoryBytes }
        if let uptimeSeconds = port.uptimeSeconds { dict["uptimeSeconds"] = uptimeSeconds }
        return dict
    }
    if let data = try? JSONSerialization.data(withJSONObject: items, options: .prettyPrinted),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    exit(0)
}

// Table output
if ports.isEmpty {
    print(showAll ? "No active ports found." : "No dev servers running.")
    exit(0)
}

func pad(_ str: String, to width: Int) -> String {
    str + String(repeating: " ", count: max(1, width - str.count))
}

print("\(pad("PORT", to: 8))\(pad("PROCESS", to: 14))\(pad("PROJECT", to: 22))DIRECTORY")
print(String(repeating: "─", count: 72))

for port in ports {
    let project = port.projectName ?? "–"
    let dir = port.directory
        .map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        ?? "–"
    print("\(pad(":\(port.port)", to: 8))\(pad(port.processName, to: 14))\(pad(project, to: 22))\(dir)")
}
