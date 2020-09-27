# chatops

Infrastructure supporting ChatOps across BSData repos.

To use the chatops commands in issue comments, add this workflow to a BSData repository:

> .github/workflows/chatops.yml

```yml
# For details and description, see https://github.com/BSData/chatops
name: ChatOps
on:
  issue_comment:
    types: [created]
jobs:
  dispatch:
    runs-on: ubuntu-latest
    if: startsWith(github.event.comment.body, '/')
    steps:
      - name: Checkout ChatOps repo
        uses: actions/checkout@v2
        with:
          repository: BSData/chatops
          path: chatops
      - name: /command dispatch
        uses: peter-evans/slash-command-dispatch@v2
        with:
          token: ${{ secrets.SLASH_COMMAND_DISPATCH_TOKEN }}
          config-from-file: chatops/commands.json

```

## Release command

Trigger by chatops '/release' or '/release bump=minor' or '/release tag=v1.2.3'.

- Create an issue comment that starts with `/release` on the first line.
- Second (non-empty) line will be used as a release title/name.
- All following lines will be interpreted as a release description/body.
- Description (even if empty) will always be appended with a comparison link to the previous release, unless there is no previous release.

### Technicalities

By default, the latest release is retrieved, it's tag parsed as a semantic version
and the patch number is increased by 1 (latest v2.2.2 -> v2.2.3).
- If there's no latest release, version will default to v1.0.0 (only if no other args specified).
- 'bump' and 'tag' are exclusive (one or the other).
- 'bump' can be either 'minor' or 'major' and specifies which part should be increased:
   - minor: latest v2.2.2 -> v2.3.0
   - major: latest v2.2.2 -> v3.0.0
- 'tag' specifies release tag manually.

### Examples:

The following, given latest release v2.2.2, will create a release v2.2.3 (increases patch/third section of semantic version).
In a case there are no releases at all, it'll fall back to creating release v1.0.0 (so it works even the first time).
> /release
>
> This is the release title (only first line after command line)!
>
> This and everything that follows will become the release description (body).

Resulting release details:

> Release tag:
> > v2.2.3
> 
> Release name: 
> > This is the release title (only first line after command line)!
> 
> Release description:
> > This and everything that follows will become the release description (body).
> > 
> > Full changelog https://github.com/test/test/compare/v2.2.2...v2.2.3

The following, given latest release v2.2.2, will create a release v2.3.0 (increases minor, resets patch).
> /release bump=minor
>
> This is title of v2.3.0

The following, given latest release v2.2.2, will create a release v3.0.0 (increases major, resets minor and patch).
> /release bump=major
>
> This is title of v3.0.0

The following, given any latest release, will create a release v1.2.3 (as specified).
> /release tag=v1.2.3
>
> This is title of v1.2.3

Workflow file: [release-command.yml](.github/workflows/release-command.yml)


## Invite command

This works on issues titled `Join Request`. When an `admin`-level user comments `/invite`,
BSData-bot will dutyfully send an invite into the repository to the issue author.

## Template workflows PR command

An `admin` user that comments `/template-workflows-pr BSData/example` will create a PR
in `example` repository that adds all GitHub Actions workflows from `TemplateDataRepo`.

This results in adding workflows that enable ChatOps (`/release`, `/invite`),
as well as enabling `publish-catpkg` workflow required to make repo work with Gallery.
