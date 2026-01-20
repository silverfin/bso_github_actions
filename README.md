# Example Repository

If you are developing liquid templates for Silverfin, thhis is an example repository that can be cloned to use as a starting point.

The following tools assume that you use the structure detailed by this repository:

- [silverfin-cli](https://github.com/silverfin/silverfin-cli)
- [silverfin-vscode](https://github.com/silverfin/silverfin-vscode)

## Project structure

```bash
/project
    /reconciliation_texts
        /[handle]
            main.liquid
            config.json
            /text_parts
                part_1.liquid
                part_2.liquid
            /tests
                README.md
                [handle]_liquid_test.yml
    /shared_parts
        /[name]
            [name].liquid
            config.json
```

# Github Actions documentation

The document will go over all the Github Actions that currently automate a couple of tasks in the Silverfin development workflow. All the actions are designed to be reused across multiple market repositories. 


## Table of Contents

* [Overview](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfa4cff673955d42e9a609fab12)
* [Individual Action Documentation](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf5d38766349a742b78f139ee4d)
  * [Label management](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfda115c3c17e34b4c833cb4b0a)
    * [Add Code Review Label (add_code_review_label.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfce44f57a01564acd95f8c0c98)
    * [Remove Code Review Label (remove_code_review_label.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf2828559422d84087b81255dc8)
  * [Authentication](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf4f743db4b6854130af8693671)
    * [Check authentication (check_auth.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf73af65c6455e4bb6a62454b15)
  * [Testing](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf13d6dbd0df1e4450b3b22691c)
    * [Check YAML files (check_tests.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf931fa1547b4b419d940464f89)
    * [Run liquid tests (run_tests.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfa4878bb5baac49cbb0c39d927)
  * [Slack updates](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfc9ca89d4b174494391ba075c5)
    * [Automated slack update (slack_changelog.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf862cf4257e68475d8b47891c6)


## Overview

All Github Actions are designed to be reused across multiple market repositories. As a result, they are stored in a specific repository in Github: [BSO Github Actions](https://github.com/silverfin/bso_github_actions). If an action needs to be added to a specific repository, these generic actions/workflows can be linked. 

Currently, there are three groups of actions available:

* Label management: Add/remove code review labels automatically
* Authentication: Check and refresh Silverfin API tokens
* Testing: Validate YAML files and run liquid tests



## Individual Action Documentation

### Label management

#### Add Code Review Label  `(add_code_review_label.yml)`

_Description_:
The workflow will automatically add a `code-review` label to pull requests when a review is requested. 

_Trigger_: 

* A reviewer is assigned/requested on any PR
* A draft PR is converted to "Ready for review"

#### Remove Code Review Label  `(remove_code_review_label.yml)`

_Description_: 
Automatically removes the "code-review" label from pull requests when review comments are provided. It will only execute if the review contains actual comments and the commenter is NOT CodeRabbit.

_Trigger_:

* A complete PR review (any type: approve, request changes, comment) is submitted
* An individual line comment has been submitted during the review



### Authentication

#### Check authentication `(check_auth.yml)`

_Description_:
Refreshes Silverfin API tokens to ensure authentication remains valid for subsequent operations.

_Trigger_: 

* The authentication workflow is run before the `run-tests` workflow to make sure that we always have the correct authentication before communicating with the platform. 


_Steps:_

* Installs the latest silverfin-cli version
* Loads the CONFIG_JSON file from the secrets
* Refreshes the tokens for all configured firms
* Updates the CONFIG_JSON file secret with the refreshed tokens


_Prerequisites_:

* `SF_API_CLIENT_ID`: Silverfin API client ID
* `SF_API_SECRET`: Silverfin API secret
* `CONFIG_JSON`: Silverfin configuration file content
* `REPO_ACCESS_TOKEN`: GitHub personal access token



### Testing

#### Check YAML files `(check_tests.yml)`

_Description:_
Validates that at least 1 `.yaml/.yml` file has been added or updated when changes are made to templates. This can be by-passed by adding the `no-test-required` to the pull request. 

_Trigger:_

* Every time new commits are pushed to a PR
* When labels are added (important for the `no-test-required` bypass logic)
* When labels are removed (re-enables validation if `no-test-required` was removed)

#### Run liquid tests `(run_tests.yml)`

_Description:_
Executes liquid tests for updated reconciliations and reconciliations that use updated shared parts.

_Trigger_:

* On every pull request to any branch (comprehensive testing)
* When code is pushed directly to main (post-merge validation)
* Runs on PR creation, updates (commits), and rebasing/merging actions


_Steps:_

* Calls `check_auth.yml` to refresh tokens
* Identifies changed liquid/config files
* Determines which templates need testing
* Runs liquid tests using silverfin-cli `run-test` command
* Supports multiple firm ID selection strategies ℹ️


_Test firm options:_
There is a certain priority when it comes to test firm id’s. Users do have some options to configure which test firm is used for the liquid tests. 


1. **Template-specific test firm id**

This is the most specific option that is available on a template by template basis. An additional attribute `test_firm_id` can be added to the `config.json` file. That firm will always get priority over the other two options.


1. **Github test firm id**

If the `test_firm_id` is not used for a specific handle, the Github action will look for a Github environment variable `SF_TEST_FIRM_ID`. This variable can be defined on [this page](https://github.com/silverfin/be_market/settings/variables/actions) (link to BE market) and will be used for every template within the market repo (so not template specific). 


1. **Default test firm id**

If none of the above options is used/defined, we will fall back to the default option: the first firm id that is present in the `config.json` file. This is again template specific, but the order cannot be changed (the smallest firm id number will always be on top). 



### Slack updates

#### Automated slack update (`slack_changelog.yml`)

_Description_: 
Posts a changelog update to Slack when a pull request is merged into the `main` branch. 

_Trigger:_

* A pull request targeting `main` is closed
* Only proceeds if the pull request was actually merged (not just closed)


_Steps:_

* Checks that the closed PR was merged
* Inherits repository/organization secrets and sends the Slack notification for the merged PR


_Prerequisites:_

* Set up a Slack workflow in the Slack settings.
    * [UK](https://slack.com/shortcuts/Ft09PPKBHW5N/f0d53e634f6fccff7335148ac0eab5d8)
    * [NL](https://slack.com/shortcuts/Ft09MT6C2CKW/c8cb614e95f1192fdbeb264361d04f73)
    * [LU](https://slack.com/shortcuts/Ft09ML70CL94/1a767ec100c7340772e48c84c24665fa)
    * [BE](https://slack.com/shortcuts/Ft09CP21L86M/ed8f5f30038e6ecca4adf2d01df996ef)
* This workflow will then generate a URL, which is called a webhook. 
* The webhook from the workflow should be stored in an environment variable in the market specific repository: `SLACK_WEBHOOK_URL`
* The Github action will create a text object (containing the formatted message) and will post this to the Slack webhook. This will then create the message in a pre-defined channel. 