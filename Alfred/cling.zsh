# Sourced by every script in the workflow. Sets $cli to the ClingCLI inside the running Cling, so the workflow speaks
# the app's own version, or else the one in the usual install places. Empty when Cling isn't installed.
#
# Finding the running app takes a process listing, which costs more than the search on every keystroke, so the
# path is kept in the workflow's cache folder and looked up again only when it stops working.
cli=""
cache=${alfred_workflow_cache:+$alfred_workflow_cache/cli-path}
[[ -n $cache && -r $cache ]] && cli=$(<$cache)
if [[ ! -x $cli ]]; then
    cli=""
    running=$(/bin/ps -Axo comm= | /usr/bin/grep -m1 '/Cling.app/Contents/MacOS/Cling$')
    for app in "${running%/Contents/MacOS/Cling}" /Applications/Cling.app ~/Applications/Cling.app; do
        if [[ -n $app && -x $app/Contents/SharedSupport/ClingCLI ]]; then
            cli=$app/Contents/SharedSupport/ClingCLI
            break
        fi
    done
    [[ -n $cli && -n $cache ]] && /bin/mkdir -p "${cache:h}" && print -r -- "$cli" >| "$cache"
fi

# A Script Filter's answer when there is no Cling to ask.
cling_missing() {
    print -r -- '{"items":[{"title":"Cling isn'\''t installed","subtitle":"↩ to get it from lowtechguys.com","arg":"https://lowtechguys.com/cling","variables":{"action":"download"}}]}'
}
