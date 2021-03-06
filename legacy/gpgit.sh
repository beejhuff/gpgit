#!/bin/bash

# Avoid any encoding problems
export LANG=C

shopt -s extglob
set -u

PROGNAME=$(basename "$0")
VERSION=1.2.0

################################################################################
# Functions
################################################################################

function usage()
{
    echo "${PROGNAME} ${VERSION}"
    echo "Usage: ${PROGNAME} <tag> [options]"
    echo
    echo 'Mandatory parameters:'
    echo '<tag>           Tagname'
    echo
    echo 'Actions:'
    echo '-h --help       Show this help message'
    echo
    echo 'Options:'
    echo '-o, --output    The output path of the compressed archive, signature and message digest.'
    echo '                Default: "git rev-parse --show-toplevel)/archive"'
    echo '-u, --username  Username of the user. Used for GPG key generation.'
    echo '                Default: git config user.name'
    echo '-e, --email     Email of the user. Used for GPG key generation.'
    echo '                Default: "git config user.email"'
    echo '-p, --project   The name of the project. Used for archive geneation.'
    echo "                Default: \"git config --local remote.origin.url \\"
    echo "                           | sed -n 's#.*/\([^.]*\)\.git#\1#p'\""
    echo '-g, --gpg       Specify (full) GPG fingerprint to use for signing.'
    echo '                Default: "git config user.signingkey"'
    echo '-w, --wget      Download source from a user-specified URL.'
    echo '                Default: Auto detection for Github URL'
    echo "-t, --tar       Valid compression options: ${config[COMPRESSION_ALGS]}"
    echo '                Default: gz'
    echo "-s, --sha       Valid message digest options: ${config[HASH_ALGS]}"
    echo '                Default: sha512'
    echo '-m, --message   Specify the tag message.'
    echo '                Default: "Release <tag>"'
    echo '-y, --yes       Assume "yes" on all questions.'
}

# Check if messages are to be printed using color
unset ALL_OFF BOLD BLUE GREEN RED YELLOW MAGENTA CYAN
if [[ -t 2 ]]; then
    # prefer terminal safe colored and bold text when tput is supported
    if tput setaf 0 &>/dev/null; then
        ALL_OFF="$(tput sgr0)"
        BOLD="$(tput bold)"
        BLUE="${BOLD}$(tput setaf 4)"
        GREEN="${BOLD}$(tput setaf 2)"
        RED="${BOLD}$(tput setaf 1)"
        YELLOW="${BOLD}$(tput setaf 3)"
        MAGENTA="${BOLD}$(tput setaf 5)"
        CYAN="${BOLD}$(tput setaf 6)"
    else
        ALL_OFF="\e[1;0m"
        BOLD="\e[1;1m"
        BLUE="${BOLD}\e[1;34m"
        GREEN="${BOLD}\e[1;32m"
        RED="${BOLD}\e[1;31m"
        YELLOW="${BOLD}\e[1;33m"
        MAGENTA="${BOLD}\e[1;35m"
        CYAN="${BOLD}\e[1;36m"
    fi
fi
readonly ALL_OFF BOLD BLUE GREEN RED YELLOW MAGENTA CYAN

function msg() {
    local mesg=$1; shift
    printf "${GREEN}==>${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

function msg2() {
    local mesg=$1; shift
    printf "${BLUE}  ->${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

function plain() {
    local mesg=$1; shift
    printf "${BOLD}    ${mesg}${ALL_OFF}\n" "$@" >&2
}

function warning() {
    local mesg=$1; shift
    printf "${YELLOW}==> WARNING:${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

function error() {
    local mesg=$1; shift
    printf "${RED}==> ERROR:${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

function info() {
    local mesg=$1; shift
    printf "${YELLOW}[!]:${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

function error_exit
{
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"
    if [[ -n "${message}" ]] ; then
        error "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
    else
        error "Error on or near line ${parent_lineno}; exiting with status ${code}"
    fi
    plain "Please report this error with the full bash output to:"
    plain "https://github.com/NicoHood/gpgit/issues"
    exit "${code}"
}

function kill_exit
{
    error "Exited due to user intervention."
    exit 1
}

function gpgit_yesno() {
    [[ "${config[YES]}" == true ]] && return
    while read -r -t 0; do read -r; done
    read -rp "${BOLD}    Continue? [Y/n]${ALL_OFF}" yesno
    if [[ "${yesno}" != [Yy]"es" && "${yesno}" != [Yy] && -n "${yesno}" ]]; then
        warning "Aborted by user"
        exit 0
    fi
}

function gpgit_check_tool() {
    if ! command -v "$1" &> /dev/null; then
        error "Required tool $1 not found. Please check your PATH variable or install the missing dependency."
        exit 1
    fi
}

################################################################################
# Parameters
################################################################################

# Trap errors
trap 'error_exit ${LINENO}' ERR
trap kill_exit SIGTERM SIGINT SIGHUP

# Check for gpg version. On some distribution gpg 2.x is installed as gpg2.
if ! gpg --version | grep "gpg (GnuPG) 2" -q; then
    if ! gpg2 --version | grep "gpg (GnuPG) 2" -q; then
        error "No gpg version 2.x available. Please install the newest gpg version."
        exit 1
    else
        GPG_BIN=gpg2
    fi
else
    GPG_BIN=gpg
fi

# Check if inside a git folder
if [[ "$(git rev-parse --is-inside-work-tree)" != "true" ]]; then
    error "Not a git repository."
    exit 1
fi

# Check input param number
if [[ $# -lt 1 ]]; then
    error "Usage: ${PROGNAME} <tag>" 1>&2
    plain "Use --help for more information."
    exit 1
fi

# Set default values in config array
declare -A config
config=(
    [OUTPUT]="$(git rev-parse --show-toplevel)/archive"
    [USERNAME]="$(git config user.name)"
    [EMAIL]="$(git config user.email)"
    [PROJECT]="$(git config --local remote.origin.url \
                 | sed -n 's#.*/\([^.]*\)\.git#\1#p')"
    [GPG]="$(git config user.signingkey)"
    [MESSAGE]="Release $1"
    [COMPRESSION]="gz"
    [COMPRESSION_ALGS]="gz|xz|lz"
    [HASH]="sha512"
    [HASH_ALGS]="sha256|sha384|sha512"
    [URL]=""
    [YES]=false
    [BRANCH]=$(git rev-parse --abbrev-ref HEAD)
)

# Print help
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage 1>&2
    exit 0
fi

# Parse input params an ovrwrite possible default or config loaded options
GETOPT_ARGS=$(getopt -o "ho:u:e:p:g:w:t:s:m:y" \
            -l "help,output:,username:,email:,project:,gpg:,wget:,tar:,sha:,message:,yes"\
            -n "$PROGNAME" -- $@)
eval set -- "$GETOPT_ARGS"

# Handle all params
while true ; do
    case "$1" in
        # Options
        -o|--output)
            config[OUTPUT]="$2"
            shift
            ;;
        -u|--username)
            config[USERNAME]="$2"
            shift
            ;;
        -e|--email)
            config[EMAIL]="$2"
            shift
            ;;
        -p|--project)
            config[PROJECT]="$2"
            shift
            ;;
        -g|--gpg)
            config[GPG]="$2"
            shift
            ;;
        -w|--wget)
            config[URL]="$2"
            shift
            ;;
        -t|--tar)
            config[COMPRESSION]="$2"
            shift
            ;;
        -s|--sha)
            config[HASH]="$2"
            shift
            ;;
        -m|--message)
            config[MESSAGE]="$2"
            shift
            ;;
        -y|--yes)
            config[YES]=true
            ;;
        # Internal
        -h|--help)
            usage 1>&2
            exit 0
            ;;
        --)
            # No more options left.
            shift
            break
           ;;
        *)
            error "Internal error!"
            exit 1
            ;;
    esac
    shift
done

config[TAG]=$1

declare -A compression_utility
compression_utility=(
    [gz]="gzip"
    [xz]="xz"
    [lz]="lzip"
)

# Validate compression parameter
case "${config[COMPRESSION]}" in
    @(${config[COMPRESSION_ALGS]}))
        # Check if compression programm is available
        gpgit_check_tool "${compression_utility[${config[COMPRESSION]}]}"
        ;;
    *)
        error "Invalid compression option. Available compressions: ${config[COMPRESSION_ALGS]}"
        exit 1
        ;;
esac

# Validate hash parameter
case "${config[HASH]}" in
    @(${config[HASH_ALGS]}))
        # Check if hash programm is available
        gpgit_check_tool "${config[HASH]}sum"
        ;;
    *)
        error "Invalid message digest option. Available message digests: ${config[HASH_ALGS]}"
        exit 1
        ;;
esac

################################################################################
msg "1. Generate new GPG key"
################################################################################

# Check for existing key
if [[ -z "${config[GPG]}" ]]; then
    if $GPG_BIN --list-secret-keys | grep uid | grep -v -q revoked; then
        error "GPG seems to be already configured on your system but git is not."
        plain "Please use gpg --list-secret-keys to show existing keys."
        plain "Afterwards set the key with git config --global user.signingkey <key>."
        plain "See the readme for more information."
        exit 1
    else
        plain "Generating an RSA 4096 GPG key for ${config[USERNAME]} <${config[EMAIL]}> valid for 3 years."
        gpgit_yesno

        # Generate ECC key command (currently not supported by Github)
        #$GPG_BIN --quick-generate-key "testuser (comment) <name@mail.com>" future-default default 3y

        # Generate RSA key command
        # https://www.gnupg.org/documentation/manuals/gnupg/Unattended-GPG-key-generation.html
        # gpg: revocation certificate stored as '/tmp/tmp.81v03YSxmI/openpgp-revocs.d/F4EDF85EFF03D746D17094D3C28B8F6BCCDF8671.rev'
        config[GPG]="$($GPG_BIN --batch --generate-key <( cat << EOF
            Key-Type: RSA
            Key-Length: 4096
            Key-Usage: cert sign auth
            Subkey-Type: RSA
            Subkey-Length: 4096
            Subkey-Usage: encrypt
            Name-Real: ${config[USERNAME]}
            #Name-Comment: Generated with gpgit
            Name-Email: ${config[EMAIL]}
            Expire-Date: 3y
            # Preferences: TODO https://security.stackexchange.com/questions/82216/how-to-change-default-cipher-in-gnupg-on-both-linux-and-windows
            %ask-passphrase
            %echo We need to generate a lot of random bytes. It is a good idea to perform
            %echo some other action (type on the keyboard, move the mouse, utilize the
            %echo disks) during the prime generation; this gives the random number
            %echo generator a better chance to gain enough entropy.
            %commit
            %echo Key generation finished
EOF
        ) 2>&1 | tee -a /dev/fd/2 | grep "revocation certificate stored as " \
               | sed 's,.*/\(.*\).rev.*,\1,')"
        NEW_GPG_KEY=true

        # Print new fingerprint
        plain "Your new GPG fingerprint is: ${config[GPG]}"
        $GPG_BIN -u "${config[GPG]}" --list-secret-keys --keyid-format LONG
    fi
else
    plain "Key already generated. Using key: ${config[GPG]}"
    NEW_GPG_KEY=false

    # Check if the full fingerprint is used
    if [[ ${#config[GPG]} -ne 40 ]]; then
        error "Please specify the full fingerprint."
        exit 1
    fi

    # Check if key exists
    if ! GPG_KEY=$($GPG_BIN --keyid-format LONG --list-secret-keys "0x${config[GPG]}"); then
        error "This GPG key is not known on this system."
        plain "Check your git config or your GNUPGHOME variable."
        exit 1
    fi

    # Check key algorithm for key
    if grep -iq "[rd]sa1024" <(echo "${GPG_KEY}"); then
        error "This key uses an insecure key algorithm. Please generate a new, secure key."
        exit 1
    fi
fi

################################################################################
msg "2. Publish your key"
################################################################################

# Check if key was just created
if [[ "${NEW_GPG_KEY}" = true ]]; then
    # Refresh setting
    config[GPG]="$(git config --global user.signingkey)"

    # Upload key
    msg2 "2.1 Submit your key to a key server"
    plain "Uploading key ${config[GPG]} to hkps://hkps.pool.sks-keyservers.net"
    gpgit_yesno
    $GPG_BIN --keyserver hkps://hkps.pool.sks-keyservers.net --send-keys "${config[GPG]}"

    # Generate public key
    msg2 "2.2 Associate GPG key with github"
    plain "Please visit Github and add the following GPG key to your profile."
    plain "https://github.com/settings/keys"
    gpgit_yesno
    $GPG_BIN --armor --export "${config[GPG]}"

    msg2 "2.3 Publish your fingerprint"
    plain "Publish your GPG fingerprint (${config[GPG]}) on your project site."
    plain "Also see https://wiki.debian.org/Keysigning"
    gpgit_yesno
else
    plain "Assuming key was already published after its creation. If not please do so."
fi

################################################################################
msg "3. Usage of GPG by git"
################################################################################

# Differenciate between new created key and (temporary) different key
if [[ "${NEW_GPG_KEY}" = true ]]; then
    GIT_CONFIG="global"
else
    GIT_CONFIG="local"
fi

#  3.1 Configure git GPG key
msg2 "3.1 Configure git GPG key"
if [[ "${config[GPG]}" != "$(git config user.signingkey)" ]]; then
    # If the key differs from the local>global>system configured key, set it locally
    plain "Git is not configured with this key."
    plain "Configuring ${GIT_CONFIG} git settings with your GPG key."
    gpgit_yesno
    git config --"${GIT_CONFIG}" user.signingkey "${config[GPG]}"
else
    plain "Git already configured with your GPG key"
fi

# Check if commit signing is enabled for this repo and ask for a switch if not
msg2 "3.2 Commit signing"
if [[ $(git config commit.gpgsign) != true ]]; then
    warning "Commit signing is disabled. Will enable it now ${GIT_CONFIG}ly."
    gpgit_yesno
    git config --"${GIT_CONFIG}" commit.gpgsign true
else
    plain "Commit signing already enabled."
fi

# Refresh tags
msg2 "3.3 Create signed git tag"
plain "Refreshing tags from upstream."
gpgit_yesno
git fetch origin --tags

# Check if tag exists
if ! git tag | grep -Fxq "${config[TAG]}"; then
    # Check if every added file has been commited
    if ! git diff --cached --exit-code > /dev/null; then
        warning 'You have added new changes but did not commit them yet. See "git status" or "git diff".'
        gpgit_yesno
    fi

    # Create new tag if not existant
    plain "Creating signed tag ${config[TAG]} and pushing it to the remote git."
    gpgit_yesno

    # Create and push new git tag
    git tag -s "${config[TAG]}" -m "${config[MESSAGE]}"
    git push origin "${config[TAG]}"
else
    plain "Tag ${config[TAG]} already exists."
fi

################################################################################
msg "4. Creation of a signed compressed release archive"
################################################################################

# Check if output path exists and ask for creation
if [[ ! -d "${config[OUTPUT]}" ]]; then
    plain "Output path does not exist. Create ${config[OUTPUT]} ?"
    gpgit_yesno
    mkdir -p "${config[OUTPUT]}"
fi

# Build archive path
config[FILENAME]="${config[PROJECT]}-${config[TAG]}"
config[EXTENSION]=".tar"
config[FILE]="${config[FILENAME]}${config[EXTENSION]}"
config[COMPRESSED_FILE]="${config[FILE]}.${config[COMPRESSION]}"
config[TAR]="${config[OUTPUT]}/${config[FILE]}"
config[COMPRESSED_TAR]="${config[TAR]}.${config[COMPRESSION]}"

# Set github URL if not otherwise specified
if [[ -z "${config[URL]}" ]]; then
    # Download the github generated archive if available
    if [[ "${config[COMPRESSION]}" == "gz" ]] && \
       git config --local remote.origin.url | grep 'github.com' -q; then
        GITHUB_REPO=`git config --local remote.origin.url | sed -e 's/.*github.com[:/]//' | sed -e 's/.git$//'`
        config[URL]="https://github.com/$GITHUB_REPO/archive/${config[TAG]}.tar.gz"
    fi
fi

# Download archive from URL
if [[ ! -f "${config[COMPRESSED_TAR]}" && -n "${config[URL]}" ]]; then
    msg2 "4.0 Download archive from online source"
    # Check if compression algorithm is valid
    if [[ "${config[COMPRESSION]}" != "${config[URL]##*.}" ]]; then
        error "Online binary format (${config[URL]##*.}) does not match selected compression format (${config[COMPRESSION]})."
        exit 1
    fi
    gpgit_check_tool wget

    plain "Downloading source from URL ${config[URL]}"
    gpgit_yesno
    wget -O "${config[COMPRESSED_TAR]}" "${config[URL]}"
fi

# Create or verify archive
msg2 "4.1 Create compressed archive"
if [[ -f "${config[COMPRESSED_TAR]}" ]]; then
    plain "Archive ${config[COMPRESSED_TAR]} already exists."
    plain "Verifying git against local source."
    gpgit_yesno

    # Verify local source against existing tar
    if git archive --format=tar --prefix "${config[FILENAME]}/" "${config[TAG]}" \
         | cmp <(${compression_utility[${config[COMPRESSION]}]} -dc ${config[COMPRESSED_TAR]}); then
        plain "Existing archive successfully verified against local source."
    else
        error "Archive differs from local source."
        exit 1
    fi
else
    plain "Creating release archive file ${config[COMPRESSED_TAR]}"
    gpgit_yesno

    # Create new archive
    git archive --format=tar --prefix "${config[FILENAME]}/" "${config[TAG]}" \
                | ${compression_utility[${config[COMPRESSION]}]} --best > "${config[COMPRESSED_TAR]}"
fi

# Create hash of the .tar.xz
msg2 "4.2 Create message digest"
if [[ -f "${config[COMPRESSED_TAR]}.${config[HASH]}" ]]; then
    plain "Message digest ${config[COMPRESSED_TAR]}.${config[HASH]} already exists. Verifying it now."
    gpgit_yesno
    if ! "${config[HASH]}sum" -c "${config[COMPRESSED_TAR]}.${config[HASH]}"; then
        error "Message digest could not be verified."
        exit 1
    fi
else
    plain "Creating message digest ${config[COMPRESSED_TAR]}.${config[HASH]}"
    gpgit_yesno
    "${config[HASH]}sum" "${config[COMPRESSED_TAR]}" > "${config[COMPRESSED_TAR]}.${config[HASH]}"
fi

# Sign .tar.xz if not existant
msg2 "4.3 Sign the sources"
if [[ -f "${config[COMPRESSED_TAR]}.sig" ]]; then
    plain "Signature ${config[COMPRESSED_TAR]}.sig already exists. Verifying it with gpg."
    gpgit_yesno
    if ! $GPG_BIN --verify "${config[COMPRESSED_TAR]}.sig"; then
        error "Signature could not be verified with gpg."
        exit 1
    fi
else
    plain "Creating signature ${config[COMPRESSED_TAR]}.sig"
    gpgit_yesno
    $GPG_BIN --local-user "${config[GPG]}" --output "${config[COMPRESSED_TAR]}.sig" --armor --detach-sign "${config[COMPRESSED_TAR]}"
fi

################################################################################
msg "5. Upload the release"
################################################################################

# Github
if git config --local remote.origin.url | grep 'github.com' -q; then
    msg2 "5.1 Github"
    gpgit_check_tool curl
    plain "Uploading to Github. Please setup a Github token first:"
    plain "(Github->Settings->Personal access tokens; public repo access)"
    gpgit_yesno

    # Create github release and upload the signature
    # http://www.barrykooij.com/create-github-releases-via-command-line/
    # https://developer.github.com/v3/repos/releases/
    # https://developer.github.com/changes/2013-09-25-releases-api/
    # https://developer.github.com/guides/getting-started/
    while read -r -t 0; do read -r; done
    read -rsp "${BOLD}    Enter your Github token:${ALL_OFF}" TOKEN
    plain ""
    API_JSON=$(printf '{"tag_name": "%s","target_commitish": "%s","name": "%s","body": "Release %s","draft": false,"prerelease": false}' \
               "${config[TAG]}" "${config[BRANCH]}" "${config[TAG]}" "${config[TAG]}")
    if ! RESULT=$(curl -s --data "${API_JSON}" "https://api.github.com/repos/${config[USERNAME]}/${config[PROJECT]}/releases" \
    -H "Accept: application/vnd.github.v3+json" -H "Authorization: token ${TOKEN}" ); then
        error "Uploading release to Github failed."
        exit 1
    fi

    # Check for error
    if grep -Eq '"message": ?"Bad credentials"' <(echo "${RESULT}"); then
        error "Bad Github credentials."
        exit 1
    fi

    # Check if release already exists
    if grep -Eq '"message": ?"Validation Failed"' <(echo "${RESULT}"); then
        if grep -Eq '"code": ?"already_exists"' <(echo "${RESULT}"); then
            warning "Release already exists."

            # Get release id for an existing release
            # https://developer.github.com/v3/repos/releases/#get-a-release-by-tag-name
            if ! RELEASE_ID=$(curl -s "https://api.github.com/repos/${config[USERNAME]}/${config[PROJECT]}/releases/tags/${config[TAG]}" \
                              | grep '^  "id": ' | tr -dc '[:digit:]'); then
                error "Accessing Github Release failed."
                exit 1
            fi
        elif grep -Eq '"message": ?"Published releases must have a valid tag"' <(echo "${RESULT}"); then
            error "Published releases must have a valid tag. Please try again later."
            exit 1
        else
            error "Unknown Github error: $(grep '"message":' <(echo "${RESULT}"))"
            exit 1
        fi
    else
        # Parse release ID
        RELEASE_ID=$(echo "${RESULT}" | grep '^  "id": ' | tr -dc '[:digit:]')
        plain "Github release created."
    fi

    # Upload the generated archive if its not gz
    if [[ "${config[COMPRESSION]}" != "gz" ]]; then
        # Upload archive
        if ! RESULT=$(curl -s "https://uploads.github.com/repos/${config[USERNAME]}/${config[PROJECT]}/releases/${RELEASE_ID}/assets?name=${config[COMPRESSED_FILE]}" \
        -H "Content-Type: application/tar" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${TOKEN}" \
        --data-binary @"${config[COMPRESSED_TAR]}"); then
            error "Uploading archive to Github failed."
            exit 1
        fi

        # Check if archive already exists
        if grep -Eq '"message": ?"Validation Failed"' <(echo "${RESULT}") && \
           grep -Eq '"code": ?"already_exists"' <(echo "${RESULT}"); then
            warning "Archive already exists."
        else
            plain "Archive uploaded."
        fi
    fi

    # Upload signature
    if ! RESULT=$(curl -s "https://uploads.github.com/repos/${config[USERNAME]}/${config[PROJECT]}/releases/${RELEASE_ID}/assets?name=${config[COMPRESSED_FILE]}.sig" \
    -H "Content-Type: application/pgp-signature" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: token ${TOKEN}" \
    --data-binary @"${config[COMPRESSED_TAR]}.sig"); then
        error "Uploading signature to Github failed."
        exit 1
    fi

    # Check if signature already exists
    if grep -Eq '"message": ?"Validation Failed"' <(echo "${RESULT}") && \
       grep -Eq '"code": ?"already_exists"' <(echo "${RESULT}"); then
        warning "Signature already exists."
    else
        plain "Signature uploaded."
    fi

    # Upload message digest
    if ! RESULT=$(curl -s "https://uploads.github.com/repos/${config[USERNAME]}/${config[PROJECT]}/releases/${RELEASE_ID}/assets?name=${config[COMPRESSED_FILE]}.${config[HASH]}" \
    -H "Content-Type: text/sha512" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: token ${TOKEN}" \
    --data-binary @"${config[COMPRESSED_TAR]}.${config[HASH]}"); then
        error "Uploading message digest to Github failed."
        exit 1
    fi

    # Check if message digest already exists
    if grep -Eq '"message": ?"Validation Failed"' <(echo "${RESULT}") && \
       grep -Eq '"code": ?"already_exists"' <(echo "${RESULT}"); then
        warning "Message digest already exists."
    else
        plain "Message digest uploaded."
    fi
else
    plain "Please upload the compressed archive, signature and message digest manually."
fi

msg "Finished without errors"
