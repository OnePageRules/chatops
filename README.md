# chatops

Infrastructure supporting ChatOps across BSData repos.

To use the chatops commands in issue comments, add this workflow to a BSData repository:

```yml
# For details and description, see https://github.com/BSData/chatops
name: ChatOps
on:
  issue_comment:
    types: [created]
jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout ChatOps repo
        uses: actions/checkout@v2
        with:
          repository: BSData/chatops
          path: chatops
      - name: /command dispatch
        uses: peter-evans/slash-command-dispatch@v1
        with:
          token: ${{ secrets.SLASH_COMMAND_DISPATCH_TOKEN }}
          config-from-file: chatops/commands.json
```

# Release command

Trigger by chatops '/release' or '/release bump=minor' or '/release tag=v1.2.3'

By default, the latest release is retrieved, it's tag parsed as a semantic version
and the patch number is increased by 1 (latest v2.2.2 -> v2.2.3).
- If there's no latest release, version will default to v1.0.0 (only if no other args specified).
- 'bump' and 'tag' are exclusive (one or the other).
- 'bump' can be either 'minor' or 'major' and specifies which part should be increased:
   - minor: latest v2.2.2 -> v2.3.0
   - major: latest v2.2.2 -> v3.0.0
- 'tag' specifies release tag manually.

Details: [release-command.yml](.github/workflows/release-command.yml)
