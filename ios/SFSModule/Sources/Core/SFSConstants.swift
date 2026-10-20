import Foundation

enum SFSConstants {
    // Perfil seguro del bot del servidor (`security_profiles.py`). Es fijo: protege el API ID de la app
    static let safeDelayMin: TimeInterval = 13
    static let safeDelayMax: TimeInterval = 30

    // Copia de `get_promo_message()` del bot del servidor. Se manda al completar cada SFS y no se puede apagar
    static let promoText = [
        "🤖 SFS STORY BOT — automatiza tu SFS",
        "",
        "Deja que tu historia haga SFS sola. Sube, baja y detecta traiciones 24/7. Todo a un clic, sin comandos.",
        "",
        "💳 Licencias desde $300 por una semana",
        "",
        "📢 Mira cómo funciona antes de decidir:",
        "👉 t.me/sfsstoryinfo",
        "",
        "Escríbeme para activarte:",
        "✈️ @rip0226",
        "📱 WhatsApp: 809 324 5449",
    ].joined(separator: "\n")
}
