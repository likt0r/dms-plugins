import QtQuick
import qs.Common

// Ohne das Schaltskript aus dem dotfiles-Repo waere das Icon nur Deko.
QtObject {
    function check(done) {
        Proc.runCommand("flugmodus.depCheck",
                        ["sh", "-c", "test -x \"$HOME/.local/bin/flugmodus\""],
                        (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null)
                return
            }
            done({
                "title": "flugmodus fehlt",
                "details": "Das Plugin schaltet ueber ~/.local/bin/flugmodus. "
                    + "Es kommt aus dem dotfiles-Repo (localbin/flugmodus) und "
                    + "wird von bin/apply verlinkt."
            })
        })
    }
}
