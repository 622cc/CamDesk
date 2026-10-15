import SwiftUI
// SDK 27 exposes a State macro alongside the property wrapper. The explicit
// alias keeps SwiftUI state usable with Command Line Tools without that plugin.
typealias CamDeskState<Value> = SwiftUI.State<Value>
