# Google Cloud setup for CloudM Migrate

Configures a Google Cloud project so CloudM Migrate can connect to a Google
Workspace tenant. Runs in Google Cloud Shell, so there is nothing to install.

## Run it

Open in Cloud Shell using the link in the
[setup guide](https://support.cloudm.io/hc/en-us/articles/14395636657436), or
clone this repository and run it yourself:

```bash
cd Migrate/CloudShell
chmod +x gcp_configuration.sh
cloudshell launch-tutorial -d tutorial.md
```

The tutorial walks through the whole process step by step. To run the script
directly:

```bash
./gcp_configuration.sh PROJECT_ID SERVICE_ACCOUNT_ID SCOPE
```

`SCOPE` is one of `Standard`, `SourceLimited`, `DestinationLimited`, `Vault`,
`Storage` or `All`. Add `--include-chat` if the migration includes Google Chat.

Use `--dry-run` first. It validates your input and prints every `gcloud` command
without running any of them, so you can see exactly what will happen before
anything changes.

## What it does

*  Creates the Google Cloud project, or selects it if it already exists
*  Creates a service account and grants it owner on that project
*  Creates a JSON key for the service account
*  Enables the Google APIs the chosen scope needs
*  Builds a prefilled link for the domain-wide delegation grant

## What you have to do yourself

**Grant domain-wide delegation.** The script cannot do this, because it happens
in the Google Admin console rather than Google Cloud. It gives you a link with
the client ID and the full scope list already filled in, so it is one click and a
confirmation.

**Configure the Chat app**, if you are migrating Google Chat. This needs values
the script has no way of knowing, including an endpoint URL from your CloudM
setup and a Google Group for visibility. The tutorial covers it, and so does the
[Chat API guide](https://support.cloudm.io/hc/en-us/articles/16098094416796).

## What you need

*  Permission to create projects in your Google Cloud organisation, or an
   existing project you administer
*  Super administrator access to the Google Workspace tenant, for the delegation
   step

## About the permissions it asks for

The service account is granted `roles/owner` on the project it is created in.
That project exists to hold the migration service account, so the grant is scoped
to it and to nothing else in your organisation.

The script creates a service account **private key**. Treat the downloaded file
like a password. The tutorial's final step removes the copy left in Cloud Shell,
which matters because the Cloud Shell home directory persists between sessions.

Two things can block it, both organisation policies rather than bugs:

*  `constraints/iam.disableServiceAccountKeyCreation` prevents key creation. It
   is enforced by default on recently created organisations and has to be
   disabled for the project before a key can be issued.
*  Creating a project needs `resourcemanager.projects.create` on the target
   organisation or folder. Without it, ask an administrator for an empty project
   and pass its ID to the script.

## Notes

The key is created in JSON format. Set the Google authentication method on the
Migrate connection to **JSON**, not P12.

Re-running with the same service account name is safe. The existing account is
reused and issued a fresh key rather than being recreated. Note that Google
Cloud limits a service account to 10 keys.

The script makes no changes when `--dry-run` is passed, and every action it takes
is written to a log alongside the key.
