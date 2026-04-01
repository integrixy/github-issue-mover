import ballerina/log;
import ballerinax/github;

configurable string githubToken = ?;
configurable string sourceRepo = ?;
configurable string targetRepo = ?;
configurable boolean closeSourceIssue = false;
configurable string[] addTargetLabels = [];
configurable string[] addSourceLabels = [];

final github:Client github = check new (config = {auth: {token: githubToken}});

type RepoInfo record {|
    string owner;
    string repo;
|};

public function main(string... args) returns error? {
    RepoInfo sourceInfo = check parseRepo(sourceRepo);
    RepoInfo targetInfo = check parseRepo(targetRepo);
    log:printInfo(string `Migrating: ${sourceInfo.owner}/${sourceInfo.repo} -> ${targetInfo.owner}/${targetInfo.repo}`);

    boolean importAll = false;
    string? label = ();
    int[] specificIssues = [];

    foreach string arg in args {
        if arg == "all" {
            importAll = true;
        } else if arg.startsWith("label=") {
            label = arg.substring(6);
        } else {
            specificIssues.push(check int:fromString(arg));
        }
    }

    if importAll {
        log:printInfo("Fetching all open issues from source repository...");
        check importIssues(sourceInfo, targetInfo);
    } else if label is string {
        log:printInfo(string `Fetching open issues with label "${label}"...`);
        check importIssues(sourceInfo, targetInfo, label);
    } else if specificIssues.length() > 0 {
        log:printInfo(string `Importing ${specificIssues.length()} specific issue(s)...`);
        foreach int issueNumber in specificIssues {
            check importIssue(sourceInfo, targetInfo, issueNumber);
        }
    } else {
        log:printWarn("Usage: bal run -- all | <issue numbers...> | label=<name>");
        return;
    }
    log:printInfo("Import completed!");
}

function parseRepo(string repoString) returns RepoInfo|error {
    string[] parts = re `/`.split(repoString);
    if parts.length() != 2 {
        return error("Invalid repository format. Expected 'owner/repo'");
    }
    return {owner: parts[0], repo: parts[1]};
}

function importLabels(string targetOwner, string targetRepo, github:Issue sourceIssue) returns string[]|error {
    string[] labelNames = [];
    foreach var label in sourceIssue.labels {
        if label is string {
            labelNames.push(label);
        } else {
            string? labelName = label.name;
            if labelName is () {
                continue;
            }
            labelNames.push(labelName);
            github:Label|error existingLabel = github->/repos/[targetOwner]/[targetRepo]/labels/[labelName].get();
            if existingLabel is error {
                _ = check github->/repos/[targetOwner]/[targetRepo]/labels.post(payload = {
                    name: labelName,
                    color: label?.color ?: "000000",
                    description: label?.description ?: ""
                });
            }
        }
    }
    foreach string additionalLabel in addTargetLabels {
        if labelNames.indexOf(additionalLabel) is () {
            labelNames.push(additionalLabel);
        }
    }
    return labelNames;
}

function importComments(string sourceOwner, string sourceRepo, int issueNumber, string targetOwner, string targetRepo, int newIssueNumber) returns error? {
    github:IssueComment[] comments = check github->/repos/[sourceOwner]/[sourceRepo]/issues/[issueNumber]/comments.get();
    foreach github:IssueComment comment in comments {
        github:NullableSimpleUser? user = comment.user;
        if user is () {
            continue;
        }
        string body = string `<a href="${user.html_url}"><img src="${user.avatar_url}" align="left" width="48" height="48" hspace="10"></img></a> **Comment by [${user.login}](${user.html_url})**${"\n"}_${comment.created_at}_${"\n"}_Comment URL ${comment.html_url}_${"\n"}${"\n"}----${"\n"}${comment.body ?: ""}`;
        _ = check github->/repos/[targetOwner]/[targetRepo]/issues/[newIssueNumber]/comments.post(payload = {body});
    }
}

function importIssues(RepoInfo sourceInfo, RepoInfo targetInfo, string? label = ()) returns error? {
    github:Issue[] issues = check github->/repos/[sourceInfo.owner]/[sourceInfo.repo]/issues.get(state = "open", labels = label, per_page = 100);
    github:Issue[] filteredIssues = filterOutPullRequests(issues);
    log:printInfo(string `Found ${filteredIssues.length()} open issues`);
    foreach github:Issue issue in filteredIssues {
        int? num = issue.number;
        if num is int {
            check importIssue(sourceInfo, targetInfo, num);
        }
    }
}

function importIssue(RepoInfo sourceInfo, RepoInfo targetInfo, int issueNumber) returns error? {
    log:printInfo(string `Importing issue #${issueNumber}...`);
    github:Issue? sourceIssue = check github->/repos/[sourceInfo.owner]/[sourceInfo.repo]/issues/[issueNumber].get();
    if sourceIssue is () {
        return error(string `Issue #${issueNumber} not found`);
    }
    github:NullableSimpleUser? issueUser = sourceIssue.user;
    if issueUser is () {
        return error(string `Issue #${issueNumber} has no user information`);
    }

    string[] labelNames = check importLabels(targetInfo.owner, targetInfo.repo, sourceIssue);
    string body = string `<a href="${issueUser.html_url}"><img src="${issueUser.avatar_url}" align="left" width="50" height="50" hspace="10"></img></a> **Issue by [${issueUser.login}](${issueUser.html_url})**${"\n"}_${sourceIssue.created_at}_${"\n"}_Originally opened as ${sourceIssue.html_url}_${"\n"}${"\n"}----${"\n"}${sourceIssue?.body ?: ""}`;
    github:Issue createdIssue = check github->/repos/[targetInfo.owner]/[targetInfo.repo]/issues.post(payload = {
        title: sourceIssue?.title,
        body,
        labels: labelNames
    });
    int? newIssueNumber = createdIssue.number;
    if newIssueNumber is () {
        return error("Created issue has no number");
    }
    log:printInfo(string `Created issue #${newIssueNumber} in target repository`);
    check importComments(sourceInfo.owner, sourceInfo.repo, issueNumber, targetInfo.owner, targetInfo.repo, newIssueNumber);
    check importAssignees(sourceIssue?.assignees, targetInfo.owner, targetInfo.repo, newIssueNumber);
    check labelAndCloseOriginalIssue(sourceInfo.owner, sourceInfo.repo, issueNumber);
    log:printInfo(string `Successfully imported #${issueNumber} -> #${newIssueNumber}`);
}

function labelAndCloseOriginalIssue(string sourceOwner, string sourceRepo, int sourceIssueNumber) returns error? {
    if addSourceLabels.length() > 0 {
        _ = check github->/repos/[sourceOwner]/[sourceRepo]/issues/[sourceIssueNumber]/labels.post(payload = addSourceLabels);
    }
    if closeSourceIssue {
        _ = check github->/repos/[sourceOwner]/[sourceRepo]/issues/[sourceIssueNumber].patch(payload = {state: "closed"});
        log:printInfo(string `Closed source issue #${sourceIssueNumber}`);
    }
}

function filterOutPullRequests(github:Issue[] issues) returns github:Issue[] =>
    from github:Issue issue in issues
    where issue.pull_request is ()
    select issue;

function importAssignees(github:SimpleUser[]? sourceAssignees, string targetOwner, string targetRepo, int targetIssueNumber) returns error? {
    if sourceAssignees is () || sourceAssignees.length() == 0 {
        return;
    }
    string[] assigneeLogins = from github:SimpleUser assignee in sourceAssignees
        let string? login = assignee.login
        where login is string
        select login;
    if assigneeLogins.length() == 0 {
        return;
    }
    _ = check github->/repos/[targetOwner]/[targetRepo]/issues/[targetIssueNumber]/assignees.post(payload = {assignees: assigneeLogins});
}
