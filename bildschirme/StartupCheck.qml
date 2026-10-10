import QtQuick
import qs.Common

// Ohne das Helferskript aus dem dotfiles-Repo kann das Plugin nichts
// schalten -- dann lieber gar nicht erst laden als eine tote Liste zeigen.
QtObject {
    function check(done) {
        Proc.runCommand("bildschirme.depCheck",
                        ["sh", "-c", "test -x \"$HOME/.local/bin/monitor-modus\""],
                        (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null)
                return
            }
            done({
                "title": "monitor-modus fehlt",
                "details": "Das Plugin steuert ~/.local/bin/monitor-modus an. "
                    + "Es kommt aus dem dotfiles-Repo (localbin/monitor-modus) "
                    + "und wird von bin/apply verlinkt."
            })
        })
    }
}
