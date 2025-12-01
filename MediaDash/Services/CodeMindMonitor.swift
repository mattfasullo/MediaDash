import Foundation
import Combine

/// Report on classification system health
struct ClassificationHealthReport: Codable {
    let generatedAt: Date
    let timeRange: DateRange
    let overallHealth: HealthStatus
    let metrics: Metrics
    let trends: Trends
    let alerts: [Alert]
    let recommendations: [String]
    
    struct DateRange: Codable {
        let start: Date
        let end: Date
        let days: Int
    }
    
    struct Metrics: Codable {
        let totalClassifications: Int
        let averageConfidence: Double
        let accuracyRate: Double // Based on feedback
        let feedbackCoverage: Double // % of classifications with feedback
        let newDocketRate: Double // % that are new dockets
        let fileDeliveryRate: Double // % that are file deliveries
        let verificationRate: Double // % of dockets verified
    }
    
    struct Trends: Codable {
        let confidenceTrend: TrendDirection
        let volumeTrend: TrendDirection
        let accuracyTrend: TrendDirection
        let confidenceChange: Double // % change over period
        let volumeChange: Double // % change over period
    }
    
    struct Alert: Codable, Identifiable {
        let id: UUID
        let severity: AlertSeverity
        let title: String
        let description: String
        let suggestedAction: String?
    }
    
    enum TrendDirection: String, Codable {
        case improving = "improving"
        case stable = "stable"
        case declining = "declining"
        case unknown = "unknown"
    }
    
    enum AlertSeverity: String, Codable {
        case info = "info"
        case warning = "warning"
        case critical = "critical"
    }
    
    enum HealthStatus: String, Codable {
        case excellent = "excellent"
        case good = "good"
        case fair = "fair"
        case needsAttention = "needs_attention"
        case critical = "critical"
        
        var description: String {
            switch self {
            case .excellent: return "Classification system is performing excellently"
            case .good: return "Classification system is performing well"
            case .fair: return "Classification system is working but could be improved"
            case .needsAttention: return "Classification system needs attention"
            case .critical: return "Classification system has critical issues"
            }
        }
    }
}

/// Service for monitoring classification system health and generating reports
@MainActor
class CodeMindMonitor: ObservableObject {
    static let shared = CodeMindMonitor()
    
    @Published var currentHealth: ClassificationHealthReport.HealthStatus = .good
    @Published var lastReport: ClassificationHealthReport?
    @Published var activeAlerts: [ClassificationHealthReport.Alert] = []
    @Published var isMonitoring = false
    
    private let history = CodeMindClassificationHistory.shared
    private let anomalyDetector = CodeMindAnomalyDetector.shared
    private let patternSuggester = CodeMindPatternSuggester.shared
    
    // Monitoring thresholds
    private let excellentConfidenceThreshold = 0.85
    private let goodConfidenceThreshold = 0.75
    private let fairConfidenceThreshold = 0.65
    private let criticalConfidenceThreshold = 0.5
    
    private let excellentAccuracyThreshold = 0.95
    private let goodAccuracyThreshold = 0.85
    private let fairAccuracyThreshold = 0.70
    
    private init() {}
    
    // MARK: - Health Monitoring
    
    /// Monitor confidence trends and overall system health
    func monitorConfidenceTrends(days: Int = 7) async -> ClassificationHealthReport.Trends {
        let trend = history.getConfidenceTrend(forLastDays: days)
        
        guard trend.count >= 2 else {
            return ClassificationHealthReport.Trends(
                confidenceTrend: .unknown,
                volumeTrend: .unknown,
                accuracyTrend: .unknown,
                confidenceChange: 0,
                volumeChange: 0
            )
        }
        
        // Calculate confidence trend
        let midpoint = trend.count / 2
        let earlierConf = trend.prefix(midpoint).map(\.avgConfidence).reduce(0, +) / Double(midpoint)
        let laterConf = trend.suffix(midpoint).map(\.avgConfidence).reduce(0, +) / Double(midpoint)
        let confChange = laterConf - earlierConf
        
        let confidenceTrend: ClassificationHealthReport.TrendDirection
        if confChange > 0.05 {
            confidenceTrend = .improving
        } else if confChange < -0.05 {
            confidenceTrend = .declining
        } else {
            confidenceTrend = .stable
        }
        
        // Calculate volume trend
        let earlierVolume = trend.prefix(midpoint).map(\.count).reduce(0, +)
        let laterVolume = trend.suffix(midpoint).map(\.count).reduce(0, +)
        let volumeChange = earlierVolume > 0 ? Double(laterVolume - earlierVolume) / Double(earlierVolume) : 0
        
        let volumeTrend: ClassificationHealthReport.TrendDirection
        if volumeChange > 0.2 {
            volumeTrend = .improving
        } else if volumeChange < -0.2 {
            volumeTrend = .declining
        } else {
            volumeTrend = .stable
        }
        
        return ClassificationHealthReport.Trends(
            confidenceTrend: confidenceTrend,
            volumeTrend: volumeTrend,
            accuracyTrend: .unknown, // Would need feedback data over time
            confidenceChange: confChange,
            volumeChange: volumeChange
        )
    }
    
    // MARK: - Metrics Calculation
    
    /// Calculate accuracy metrics for a time range
    func calculateAccuracyMetrics(days: Int = 30) async -> ClassificationHealthReport.Metrics {
        let stats = history.getStats(forLastDays: days)
        
        let feedbackCoverage = stats.totalClassifications > 0
            ? Double(stats.feedbackCount) / Double(stats.totalClassifications)
            : 0
        
        let newDocketRate = stats.totalClassifications > 0
            ? Double(stats.newDocketCount) / Double(stats.totalClassifications)
            : 0
        
        let fileDeliveryRate = stats.totalClassifications > 0
            ? Double(stats.fileDeliveryCount) / Double(stats.totalClassifications)
            : 0
        
        // Calculate verification rate from recent records
        let recentRecords = history.getRecentClassifications(limit: 100)
        let verifiedCount = recentRecords.filter { $0.wasVerified }.count
        let verificationRate = recentRecords.isEmpty ? 0 : Double(verifiedCount) / Double(recentRecords.count)
        
        return ClassificationHealthReport.Metrics(
            totalClassifications: stats.totalClassifications,
            averageConfidence: stats.averageConfidence,
            accuracyRate: stats.accuracy,
            feedbackCoverage: feedbackCoverage,
            newDocketRate: newDocketRate,
            fileDeliveryRate: fileDeliveryRate,
            verificationRate: verificationRate
        )
    }
    
    // MARK: - Anomaly Detection Integration
    
    /// Detect anomalies and convert to alerts
    func detectAnomalies() async -> [ClassificationHealthReport.Alert] {
        await anomalyDetector.runAllChecks()
        
        var alerts: [ClassificationHealthReport.Alert] = []
        let summary = anomalyDetector.getAnomalySummary()
        
        if summary.high > 0 {
            alerts.append(ClassificationHealthReport.Alert(
                id: UUID(),
                severity: .critical,
                title: "\(summary.high) High Severity Issues",
                description: "Found \(summary.high) high-severity classification issues that need immediate attention.",
                suggestedAction: "Review low-confidence and misclassified emails in the anomaly list."
            ))
        }
        
        if summary.medium > 0 {
            alerts.append(ClassificationHealthReport.Alert(
                id: UUID(),
                severity: .warning,
                title: "\(summary.medium) Medium Severity Issues",
                description: "Found \(summary.medium) medium-severity issues that should be reviewed.",
                suggestedAction: "Consider providing feedback on flagged classifications."
            ))
        }
        
        // Check for confidence drops
        let trends = await monitorConfidenceTrends()
        if trends.confidenceTrend == .declining && trends.confidenceChange < -0.1 {
            alerts.append(ClassificationHealthReport.Alert(
                id: UUID(),
                severity: .warning,
                title: "Declining Confidence Trend",
                description: "Classification confidence has dropped by \(String(format: "%.1f%%", abs(trends.confidenceChange) * 100)) over the past week.",
                suggestedAction: "Review recent classifications and provide feedback to improve accuracy."
            ))
        }
        
        activeAlerts = alerts
        return alerts
    }
    
    // MARK: - Report Generation
    
    /// Generate a comprehensive health report
    func generateReport(days: Int = 30) async -> ClassificationHealthReport {
        isMonitoring = true
        defer { isMonitoring = false }
        
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate) ?? endDate
        
        // Calculate all metrics
        let metrics = await calculateAccuracyMetrics(days: days)
        let trends = await monitorConfidenceTrends(days: min(days, 14))
        let alerts = await detectAnomalies()
        
        // Determine overall health
        let health = calculateOverallHealth(metrics: metrics, trends: trends, alertCount: alerts.count)
        
        // Generate recommendations
        let recommendations = generateRecommendations(metrics: metrics, trends: trends)
        
        let report = ClassificationHealthReport(
            generatedAt: Date(),
            timeRange: ClassificationHealthReport.DateRange(start: startDate, end: endDate, days: days),
            overallHealth: health,
            metrics: metrics,
            trends: trends,
            alerts: alerts,
            recommendations: recommendations
        )
        
        lastReport = report
        currentHealth = health
        
        return report
    }
    
    // MARK: - Health Calculation
    
    private func calculateOverallHealth(
        metrics: ClassificationHealthReport.Metrics,
        trends: ClassificationHealthReport.Trends,
        alertCount: Int
    ) -> ClassificationHealthReport.HealthStatus {
        var score = 100.0
        
        // Confidence impact (0-30 points)
        if metrics.averageConfidence >= excellentConfidenceThreshold {
            // Full points
        } else if metrics.averageConfidence >= goodConfidenceThreshold {
            score -= 10
        } else if metrics.averageConfidence >= fairConfidenceThreshold {
            score -= 20
        } else if metrics.averageConfidence >= criticalConfidenceThreshold {
            score -= 30
        } else {
            score -= 40
        }
        
        // Accuracy impact (0-30 points)
        if metrics.accuracyRate >= excellentAccuracyThreshold {
            // Full points
        } else if metrics.accuracyRate >= goodAccuracyThreshold {
            score -= 10
        } else if metrics.accuracyRate >= fairAccuracyThreshold {
            score -= 20
        } else {
            score -= 30
        }
        
        // Trend impact (0-20 points)
        if trends.confidenceTrend == .declining {
            score -= 15
        } else if trends.confidenceTrend == .improving {
            score += 5
        }
        
        // Alert impact (0-20 points)
        score -= Double(min(alertCount * 5, 20))
        
        // Convert score to health status
        if score >= 90 {
            return .excellent
        } else if score >= 75 {
            return .good
        } else if score >= 60 {
            return .fair
        } else if score >= 40 {
            return .needsAttention
        } else {
            return .critical
        }
    }
    
    private func generateRecommendations(
        metrics: ClassificationHealthReport.Metrics,
        trends: ClassificationHealthReport.Trends
    ) -> [String] {
        var recommendations: [String] = []
        
        if metrics.feedbackCoverage < 0.1 {
            recommendations.append("Provide feedback on more classifications to improve accuracy tracking.")
        }
        
        if metrics.averageConfidence < goodConfidenceThreshold {
            recommendations.append("Review and improve classification prompts to increase confidence scores.")
        }
        
        if metrics.verificationRate < 0.5 {
            recommendations.append("Ensure Asana and metadata sources are connected for docket verification.")
        }
        
        if trends.confidenceTrend == .declining {
            recommendations.append("Confidence is declining. Review recent classifications and provide feedback.")
        }
        
        if metrics.totalClassifications < 10 {
            recommendations.append("More classification data needed for accurate health assessment.")
        }
        
        if recommendations.isEmpty {
            recommendations.append("System is performing well. Continue providing feedback to maintain accuracy.")
        }
        
        return recommendations
    }
    
    // MARK: - Scheduled Monitoring
    
    /// Start periodic monitoring (call this on app launch)
    func startPeriodicMonitoring(interval: TimeInterval = 3600) { // Default: hourly
        // Generate initial report
        Task {
            _ = await generateReport()
        }
        
        // Schedule periodic reports (in production, use proper scheduling)
        // For now, just run once on start
    }
}

