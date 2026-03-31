import ballerina/io;
import ballerinax/github;

// GitHub Personal Access Token for authentication
configurable string githubToken = ?;
// Source repository (format: "owner/repo")
configurable string sourceRepo = ?;
// Target repository (format: "owner/repo")
configurable string targetRepo = ?;
// Whether to close the original issue in the source repository after import
configurable boolean closeSourceIssue = ?;
//Add labels to the imported issue in the target repository
configurable string addTargetLabels = ?;
//Add labels to the imported issue in the source repository
configurable string addSourceLabels = ?;

final github:Client githubClient = check new (config = {auth: {token: githubToken}});

type RepoInfo record {|
    string owner;
    string repo;
|};

public function main(string... args) returns error? {
    io:println("App started");
    // Parse source and target repositories
    RepoInfo sourceRepoInfo = check parseRepo(sourceRepo);
    RepoInfo targetRepoInfo = check parseRepo(targetRepo);

    io:println(string `Source: ${sourceRepoInfo.owner}/${sourceRepoInfo.repo}`);
    io:println(string `Target: ${targetRepoInfo.owner}/${targetRepoInfo.repo} ${"\n"}`);

    boolean importAllIssues = false;
    string? label = ();
    int[] specificIssues = [];

    foreach string arg in args {
        if arg == "all" {
            importAllIssues = true;
        } else if arg.startsWith("label=") {
            label = arg.substring(6);
        } else {
            specificIssues.push(check int:fromString(arg));
        }
    }
    if importAllIssues {
        io:println("Fetching all open issues from source repository...");
        check importIssues(sourceRepoInfo, targetRepoInfo);
    } else if label is string {
        io:println(string `Fetching open issues with label "${label}" from source repository...`);
        check importIssues(sourceRepoInfo, targetRepoInfo, label);
    } else if specificIssues.length() > 0 {
        io:println(string `Importing ${specificIssues.length()} specific issue(s)...${"\n"}`);
        foreach int issueNumber in specificIssues {
            check importIssue(sourceRepoInfo, targetRepoInfo, issueNumber);
        }
    } else {
        printUsage();
        return;
    }
    io:println("Import completed!");
}

function printUsage() {
    io:println("Incorrect usage. Please specify which issues to import.");
    io:println("Usage:");
    io:println("  Import all open issues:");
    io:println("    bal run -- all");
    io:println("");
    io:println("  Import specific issues:");
    io:println("    bal run -- 123 456 789");
    io:println("");
    io:println("  Import issues with a specific label:");
    io:println("    bal run -- label=bug");
    io:println("");
}

function parseRepo(string repoString) returns RepoInfo|error {
    string[] parts = re `/`.split(repoString);
    if parts.length() != 2 {
        return error("Invalid repository format. Expected format: owner/repo");
    }
    return {
        owner: parts[0],
        repo: parts[1]
    };
}

function importLabels(string targetOwner, string targetRepo, github:Issue sourceIssue) returns string[]|error {
    (string|record {string name?; string? description?; string? color?;})[] sourceLabels = sourceIssue.labels;
    string[] labelNames = [];

    foreach var label in sourceLabels {
        if label is string {
            labelNames.push(label);
        } else {
            string? labelName = label.name;
            if labelName is () {
                continue;
            }
            labelNames.push(labelName);
            github:Label|error existingLabel = githubClient->/repos/[targetOwner]/[targetRepo]/labels/[labelName].get();
            if existingLabel is error {
                string? labelColor = label?.color;
                string? labelDescription = label?.description;
                github:Repo_labels_body labelPayload = {
                    name: labelName,
                    color: labelColor ?: "000000",
                    description: labelDescription ?: ""
                };
                _ = check githubClient->/repos/[targetOwner]/[targetRepo]/labels.post(payload = labelPayload);
            }
        }
    }
    string[] additionalLabels = re `,`.split(addTargetLabels);
    foreach string additionalLabel in additionalLabels {
        if labelNames.indexOf(additionalLabel) is () {
            labelNames.push(additionalLabel);
        }
    }
    return labelNames;
}

function importComments(string sourceOwner, string sourceRepo, int issueNumber, string targetOwner, string targetRepo, int newIssueNumber) returns error? {
    github:IssueComment[] comments = check githubClient->/repos/[sourceOwner]/[sourceRepo]/issues/[issueNumber]/comments.get();
    foreach github:IssueComment comment in comments {
        github:NullableSimpleUser? commentUser = comment.user;
        if commentUser is () {
            continue;
        }
        string newCommentBody = string `<a href="${commentUser.html_url}"><img src="${commentUser.avatar_url}" align="left" width="48" height="48" hspace="10"></img></a> **Comment by [${commentUser.login}](${commentUser.html_url})**${"\n"}_${comment.created_at}_${"\n"}_Comment URL ${comment.html_url}_${"\n"}${"\n"}----${"\n"}${comment.body ?: ""}`;
        github:Issue_number_comments_body commentPayload = {
            body: newCommentBody
        };
        _ = check githubClient->/repos/[targetOwner]/[targetRepo]/issues/[newIssueNumber]/comments.post(payload = commentPayload);
    }
}

function importIssues(RepoInfo sourceRepoInfo, RepoInfo targetRepoInfo, string? label = ()) returns error? {
    github:Issue[] issues = check githubClient->/repos/[sourceRepoInfo.owner]/[sourceRepoInfo.repo]/issues.get(state = "open", labels = label, per_page = 100);
    github:Issue[] filteredIssues = filterOutPullRequests(issues);
    io:println(string `Found ${filteredIssues.length()} open issues ${"\n"}`);
    foreach github:Issue issue in filteredIssues {
        int? issueNumber = issue.number;
        if issueNumber is int {
            check importIssue(sourceRepoInfo, targetRepoInfo, issueNumber);
        }
    }
}

// Import a single issue from source to target repository
function importIssue(RepoInfo sourceRepoInfo, RepoInfo targetRepoInfo, int issueNumber) returns error? {
    io:println(string `Importing issue #${issueNumber}...`);
    github:Issue? sourceIssue = check githubClient->/repos/[sourceRepoInfo.owner]/[sourceRepoInfo.repo]/issues/[issueNumber].get();
    if sourceIssue is () {
        return error(string `Issue #${issueNumber} not found`);
    }
    github:NullableSimpleUser? issueUser = sourceIssue.user;
    if issueUser is () {
        return error(string `Issue #${issueNumber} has no user information`);
    }

    // Import labels
    string[] labelNames = check importLabels(targetRepoInfo.owner, targetRepoInfo.repo, sourceIssue);
    // Import body
    string newBody = string `<a href="${issueUser.html_url}"><img src="${issueUser.avatar_url}" align="left" width="50" height="50" hspace="10"></img></a> **Issue by [${issueUser.login}](${issueUser.html_url})**${"\n"}_${sourceIssue.created_at}_${"\n"}_Originally opened as ${sourceIssue.html_url}_${"\n"}${"\n"}----${"\n"}${sourceIssue?.body ?: ""}`;
    github:Repo_issues_body issuePayload = {
        title: sourceIssue?.title,
        body: newBody,
        labels: labelNames
    };
    github:Issue createdIssue = check githubClient->/repos/[targetRepoInfo.owner]/[targetRepoInfo.repo]/issues.post(payload = issuePayload);
    int? newIssueNumber = createdIssue.number;
    if newIssueNumber is () {
        return error("Created issue has no number");
    }
    io:println(string `Created issue #${newIssueNumber} in target repository`);
    // Import comments
    check importComments(sourceRepoInfo.owner, sourceRepoInfo.repo, issueNumber, targetRepoInfo.owner, targetRepoInfo.repo, newIssueNumber);
    // Import assignees
    check importAssignees(sourceIssue?.assignees, targetRepoInfo.owner, targetRepoInfo.repo, newIssueNumber);
    check labelAndCloseOriginalIssue(sourceRepoInfo.owner, sourceRepoInfo.repo, issueNumber);

    io:println(string `Successfully imported issue #${issueNumber} -> #${newIssueNumber}`);
}

// Close the original issue in the source repository
function labelAndCloseOriginalIssue(string sourceOwner, string sourceRepo, int sourceIssueNumber) returns error? {

        string[] additionalLabels = re `,`.split(addSourceLabels);
        _ = check githubClient->/repos/[sourceOwner]/[sourceRepo]/issues/[sourceIssueNumber]/labels.post(
            payload = additionalLabels
        );
    
    if closeSourceIssue {
        _ = check githubClient->/repos/[sourceOwner]/[sourceRepo]/issues/[sourceIssueNumber].patch(payload = {state: "closed"});
        io:println(string `Closed source issue #${sourceIssueNumber}`);
    }
}

// Filter out pull requests from the issues list
function filterOutPullRequests(github:Issue[] issues) returns github:Issue[] {
    github:Issue[] filtered = [];
    foreach github:Issue issue in issues {
        if issue.pull_request is () {
            filtered.push(issue);
        }
    }
    return filtered;
}

function importAssignees(github:SimpleUser[]? sourceAssignees, string targetOwner, string targetRepo, int targetIssueNumber) returns error? {
    if sourceAssignees is () || sourceAssignees.length() == 0 {
        return;
    }
    string[] assigneeLogins = [];
    foreach github:SimpleUser assignee in sourceAssignees {
        string? login = assignee.login;
        if login is string {
            assigneeLogins.push(login);
        }
    }
    if assigneeLogins.length() == 0 {
        return;
    }
    _ = check githubClient->/repos/[targetOwner]/[targetRepo]/issues/[targetIssueNumber]/assignees.post(payload = {assignees: assigneeLogins});
}
