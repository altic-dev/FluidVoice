import { readFileSync } from "node:fs";

import {
  ensureLabel,
  githubRequest,
  paginate,
  removeLabel,
  repoContext,
  upsertIssueComment,
} from "./github-api.mjs";

const LABEL = {
  name: "awaiting response",
  color: "FBCA04",
  description: "Issue will close after three days unless this label is removed.",
};
const DAYS_BEFORE_CLOSE = 3;
const CLOSE_MARKER = "<!-- fluidvoice-awaiting-response-close -->";

function eventPayload() {
  return JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
}

async function latestLabelTime(context, issueNumber) {
  const events = await paginate(
    `/repos/${context.owner}/${context.repo}/issues/${issueNumber}/events`,
  );
  const labelEvents = events.filter(
    (event) => event.event === "labeled" && event.label?.name === LABEL.name,
  );
  const latest = labelEvents.reduce(
    (current, event) =>
      !current || new Date(event.created_at) > new Date(current.created_at)
        ? event
        : current,
    null,
  );
  return latest ? new Date(latest.created_at) : null;
}

async function warnOrClose(context, issue, now = new Date()) {
  if (issue.pull_request) return;

  const labeledAt = await latestLabelTime(context, issue.number);
  if (!labeledAt) return;

  const closesAt = new Date(
    labeledAt.getTime() + DAYS_BEFORE_CLOSE * 24 * 60 * 60 * 1000,
  );

  if (now < closesAt) return;

  await upsertIssueComment(
    context,
    issue.number,
    CLOSE_MARKER,
    "Closing this issue because it remained labeled `awaiting response` for three days.",
  );
  await githubRequest(
    "PATCH",
    `/repos/${context.owner}/${context.repo}/issues/${issue.number}`,
    { state: "closed", state_reason: "not_planned" },
  );
}

async function scanLabeledIssues(context) {
  const query = encodeURIComponent(
    `repo:${context.owner}/${context.repo} is:issue is:open label:"${LABEL.name}"`,
  );
  let page = 1;

  while (true) {
    const results = await githubRequest(
      "GET",
      `/search/issues?q=${query}&per_page=100&page=${page}`,
    );
    for (const issue of results.items) await warnOrClose(context, issue);
    if (results.items.length < 100) break;
    page += 1;
  }
}

async function main() {
  const context = repoContext();
  await ensureLabel(context, LABEL);

  if (process.env.GITHUB_EVENT_NAME === "issue_comment") {
    const event = eventPayload();
    const hasLabel = event.issue?.labels?.some(
      (label) => (typeof label === "string" ? label : label.name) === LABEL.name,
    );

    if (event.action === "created" && !event.issue?.pull_request && hasLabel) {
      await removeLabel(context, event.issue.number, LABEL.name);
    }
    return;
  }

  if (process.env.GITHUB_EVENT_NAME === "issues") {
    const event = eventPayload();
    if (event.action === "labeled" && event.label?.name === LABEL.name) {
      await warnOrClose(context, event.issue);
    }
    return;
  }

  await scanLabeledIssues(context);
}

await main();
