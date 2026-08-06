# Configure Google Cloud for CloudM Migrate

## Before you start

This tutorial sets up a Google Cloud project so CloudM Migrate can connect to your
Google Workspace tenant. It creates the project if it does not exist, creates a
service account with a JSON key, enables the Google APIs Migrate uses, and
optionally adds Google Chat.

One step cannot be automated: granting domain-wide delegation in the Google Admin
console. The tutorial gives you a prefilled link for it near the end.

You will need permission to create projects in Google Cloud, or an existing
project you administer, plus super administrator access to the Google Workspace
tenant. Allow about 15 minutes.

The script creates a service account private key. Treat it like a password. The
last step removes the copy left behind in Cloud Shell.

Click **Next** to begin.

## Select your project

Use the picker below to choose the project you want to use, or create a new one.

<walkthrough-project-setup billing="true"></walkthrough-project-setup>

The script can also create a project for you if you would rather pass a new
project id straight to it. If you do that, the id must be 6 to 30 lowercase
letters, digits or hyphens, must start with a letter and must not end with a
hyphen.

### Confirm the target project

Run this. It prints the project that everything will be created in:

```bash
echo "Target project: <walkthrough-project-id/>"
```

Check the name it prints is the project you intend to configure, because the
later steps create a service account with owner permissions there and issue a
private key for it.

If it prints the wrong project, go back to the picker above and select the right
one.

### Confirm who you are signed in as

```bash
gcloud auth list --filter=status:ACTIVE --format="value(account)"
```

If nothing is returned, run `gcloud auth login` and follow the prompts.

## Choose a scope

The scope controls which OAuth scopes you grant and which APIs get enabled.

*  **Standard**, full mailbox access. The usual choice for a Google Workspace
   migration.
*  **SourceLimited**, read-only mail, for migrating **out of** a Google tenant
   without granting write access to it.
*  **DestinationLimited**, mail insert only, for migrating **into** one without
   granting read access.
*  **Vault**, Standard plus Google Vault and Cloud Storage.
*  **Storage**, Standard plus Cloud Storage.
*  **All**, everything above. Only use this if you need it, since it grants the
   broadest access.

If you are not sure which to pick, check with CloudM support before continuing.

### Migrating Google Chat as well?

Decide now. You will add `--include-chat` to the commands in the next two steps,
and there is an extra step later to configure the Chat app in the console. One of
its settings cannot be undone once saved, so read that step before changing
anything.

## Preview the changes

This validates your input and prints every `gcloud` call without running any of
them. Nothing in your tenant changes.

```bash
./gcp_configuration.sh --dry-run <walkthrough-project-id/> cloudm-migrate Standard
```

Change `Standard` if you picked a different scope, and add `--include-chat` if you
are migrating Chat. The copy button pastes the command without running it, so you
can edit it before pressing enter.

Read the output and check the project id and scope are what you expect.

### If something looks wrong

If the command contains `<walkthrough-project-id/>` as literal text rather than
your project id, replace it by hand.

If it fails at the project stage, your account probably cannot create projects in
your organisation. Ask whoever administers it for an empty project and pass that
project id instead.

To use your own service account name, replace `cloudm-migrate` here and in the
next step. It must be 6 to 30 lowercase letters, digits or hyphens, start with a
letter and not end with a hyphen. An account that already exists is reused and
issued a new key rather than recreated.

## Run the configuration

This step makes real changes. It creates a service account with owner permissions
on **<walkthrough-project-id/>** and issues a private key for it, so check that is
the right project before running it.

```bash
./gcp_configuration.sh <walkthrough-project-id/> cloudm-migrate Standard
```

Apply the same edits as the previous step if you changed the scope, added
`--include-chat`, or used your own service account name.

This takes a few minutes. When it finishes it prints the client id, the service
account email and the key path, and leaves a clickable delegation link. Leave that
output on screen, because the next steps use it.

If key creation fails, your organisation most likely enforces
`constraints/iam.disableServiceAccountKeyCreation`. Someone with organisation
policy admin rights needs to disable it for this project, then you can re-run with
the same service account name.

## Grant domain-wide delegation

This is the step that most often goes wrong, because it involves transferring a
long list of scopes without altering any of it. The script builds a link that
fills the form in for you so there is nothing to retype.

You need to be a Google Workspace super administrator for this step.

### Open the prefilled link

Look at the terminal output from the previous step. The script printed a
clickable link reading **>>> Grant domain wide delegation <<<**.

Control-click it, or command-click on a Mac, to open the delegation form with
your client id and all of your scopes already filled in.

If the link is not clickable in your terminal, the same url is saved here:

<walkthrough-editor-open-file filePath="cloudm/gcpconfig/delegation_url.txt">
Open delegation_url.txt in the editor
</walkthrough-editor-open-file>

### Authorise it

The Client ID and OAuth scopes fields should already be filled in.

1.  Check the Client ID matches the one the script printed
2.  Check the OAuth scopes field is **not empty**
3.  Click **Authorise**

If both fields are populated, you are done with this step.

### If the fields are empty

The prefill is a convenience and the console may ignore it. Enter the values by
hand instead:

1.  Go to https://admin.google.com/ac/owl/domainwidedelegation
2.  Click **Add new**
3.  Paste the client id the script printed into the Client ID field
4.  Open <walkthrough-editor-open-file filePath="cloudm/gcpconfig/scopes.txt">scopes.txt</walkthrough-editor-open-file>, copy the whole line, and paste it into the OAuth scopes field
5.  Click **Authorise**

Copy the scopes from the file rather than from the terminal, where the line will
have wrapped and is easy to truncate.

### Check it saved correctly

Reopen the entry and confirm the number of scopes matches what the script
printed. A missing scope causes migration failures later that are very hard to
trace back to this step.

Delegation changes can take a few minutes to take effect. If your organisation
requires multi-party approval for admin actions, another super administrator may
need to approve this before it becomes active.

## Configure the Google Chat app

Skip this step unless you used `--include-chat`. Click **Next** if you are not
migrating Google Chat.

The script enabled the Chat API and put the Chat scopes in the delegation grant.
The Chat app itself has to be configured by hand, because it needs values the
script cannot know.

Open the Chat API page, then click the **Configuration** tab:

https://console.cloud.google.com/apis/api/chat.googleapis.com?project=<walkthrough-project-id/>

### Read this before you change anything

Leave **"Build this Chat app as a Workspace add-on" unticked.**

That setting cannot be undone once saved. If you save it, you have to abandon this
project and start again with a brand new one.

### Application info

*  **App name**, what users see when a message is migrated. Keep it to 25
   characters or fewer so it is not truncated.
*  **Avatar URL**, a publicly reachable HTTPS PNG or JPG, square.
*  **Description**, 40 characters or fewer.

### Interactive features

*  **Enable interactive features**, on.
*  **Join spaces and group conversations**, on. Required for migrating into
   Google Spaces.

### Connection settings

*  **Connection method**, HTTP endpoint URL.
*  **App URL**, the endpoint from your CloudM project setup. Source connections
   use the source domain, destination connections use the destination domain.
*  **Authentication Audience**, Project number. The script printed the number to
   use.

### Visibility

Choose **make this Chat app available to specific people and groups**, then enter
a Google Group containing the super admin account used for the connection and
every migrating user.

A dynamic group handles membership automatically, or use a static group with a CSV
bulk import. Membership changes can take up to 24 hours to propagate, so do this
early.

### Logs

Turn on **log errors to Logging**. Worth having when a connection misbehaves.

### Save and check the status

Save, then scroll back to the top and check **App Status** reads
**LIVE - available to users**. If it does not, set it with the dropdown and save
again.

Full reference: https://support.cloudm.io/hc/en-us/articles/16098094416796

## Download the key file

The key was created inside Cloud Shell, not on the machine running CloudM
Migrate, so you need to download it.

The script attempts the download for you. If it did not start, run:

```bash
cloudshell download ~/cloudm/gcpconfig/*_key.json
```

You can also use the three dot menu at the top of the Cloud Shell window,
choose **Download**, and enter the path the script printed.

Save the file somewhere secure that the Migrate server can reach.

## Set up the connection in CloudM Migrate

In CloudM Migrate, create or edit your Google Workspace connection and enter:

*  **Service account email**, as printed by the script
*  **Key file**, the JSON file you just downloaded
*  **Authentication method**, set to **JSON**

The authentication method matters. This script creates a JSON key, not a p12
key, so a connection left on P12 will fail to authenticate.

Test the connection before starting a migration. If it fails, the most likely
cause is that domain-wide delegation has not finished propagating, so wait a few
minutes and try again.

## Remove the key from Cloud Shell

Once the key is stored safely and the connection tests successfully, delete the
copy in Cloud Shell:

```bash
shred -u ~/cloudm/gcpconfig/*_key.json
```

Do not skip this. Your Cloud Shell home directory persists between sessions, so
without this the private key stays on disk.

The log and the scope list contain no secrets, so you can leave them. To remove
everything:

```bash
rm -rf ~/cloudm/gcpconfig
```

## You are done

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Your project, service account and APIs are configured, and CloudM Migrate can
authenticate to your Google Workspace tenant.

To start over, either use a different service account name or delete the old
account first with `gcloud iam service-accounts delete`. To restart this tutorial,
run `cloudshell launch-tutorial -d tutorial.md`.
