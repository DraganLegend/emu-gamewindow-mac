import Foundation
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.
func launcherSummary(_ json: String) -> String { LauncherModel.summary(Data(json.utf8)) }
