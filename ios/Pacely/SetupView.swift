import SwiftUI

private struct TokenResponse: Codable {
    let token: String
    let widget: String
}

struct SetupView: View {
    @EnvironmentObject var state: AppState
    @State private var server = Store.server.isEmpty ? "" : Store.server
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var partner = false

    private let teal = Color(hex: "#2F7D78")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    Image(systemName: "circle.dotted.circle")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(teal)
                    Spacer()
                }
                .padding(.top, 40)

                Text("Pacely")
                    .font(Look.f(.largeTitle).bold())
                    .frame(maxWidth: .infinity)
                Text("Your plan: connect to your own Pacely server. Nothing is sent anywhere else.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Server address").font(Look.f(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                    TextField("plan.example.com", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pacely password").font(Look.f(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                    SecureField("Password", text: $password)
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
                }

                if let error = error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(Look.f(.callout))
                }

                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().tint(.white) } else { Text("Connect").bold() }
                        Spacer()
                    }
                    .padding(.vertical, 15)
                    .background(teal, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .disabled(busy || server.isEmpty || password.isEmpty)

                Text("Your password is only used once to link this phone. You can unlink it any time in Me → iPhone app settings.")
                    .font(Look.f(.footnote))
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 6)
                Button { useThisPhone() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Just use it on this phone", systemImage: "iphone").font(Look.f(.headline))
                        Text("No server needed. Your plans stay on this iPhone. Sharing with a partner, live journeys and home screen widgets need a server.")
                            .font(Look.f(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Button { partner = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("I help someone with their plan", systemImage: "heart.text.square").font(Look.f(.headline))
                        Text("For partners and family: use the link they sent you. No password needed.")
                            .font(Look.f(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $partner) { PartnerSetupView().environmentObject(state) }
            }
            .padding(24)
        }
    }

    @MainActor
    private func useThisPhone() {
        Store.localOnly = true
        Task {
            try? await LocalEngine.shared.start()
            state.didSetUp()
        }
    }

    @MainActor
    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        let base = Store.normalise(server)
        Store.server = base
        do {
            let data = try await API.request("/api/token", method: "POST", body: ["password": password], useToken: false)
            let r = try JSONDecoder().decode(TokenResponse.self, from: data)
            Store.token = r.token
            Store.widgetCode = r.widget
            password = ""
            state.didSetUp()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
