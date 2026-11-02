import Foundation

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--bench") { exit(Bench.run(arguments)) }
        if arguments.contains("--live-test") { exit(LiveTest.run(arguments)) }
        if arguments.contains("--perf-report") { exit(PerfReport.run(arguments)) }
        #if PROMO
        if arguments.contains("--capture-app") { exit(PromoCommands.capture(arguments)) }
        if arguments.contains("--promo-stems") { exit(PromoCommands.stems(arguments)) }
        if arguments.contains("--promo-take") { exit(PromoTake.run(arguments)) }
        #endif
        PrismApp.main()
    }
}
