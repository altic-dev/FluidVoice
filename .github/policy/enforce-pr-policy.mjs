import { readFileSync } from "node:fs";

import { validatePullRequest } from "./github-policy.mjs";
import {
  addLabels,
  ensureLabel,
  githubRequest,
  paginate,
  removeLabel,
  repoContext,
  upsertIssueComment,
} from "./github-api.mjs";

const MARKER = "<!-- fluidvoice-pr-policy -->";
const HOURS_BEFORE_CLOSE = 48;

const LABELS = {
  template: {
    name: "needs PR template",
    color: "D93F0B",
    description: "Pull request is missing required template content.",
  },
  screenshots: {
    name: "needs screenshots",
    color: "FBCA04",
    description: "Pull request needs screenshot or video evidence.",
  },
};

function eventPayload() {
  return JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
}

function hoursSince(value) {
  return (Date.now() - new Date(value).getTime()) / 36e5;
}

async function changedFiles(context, pullNumber) {
  const { owner, repo } = context;
  const files = await paginate(`/repos/${owner}/${repo}/pulls/${pullNumber}/files`);
  return files.map((file) => file.filename);
}

async function existingWarningComment(context, pullNumber) {
  const comments = await paginate(
    `/repos/${context.owner}/${context.repo}/issues/${pullNumber}/comments`,
  );
  return comments.find((comment) => comment.body?.includes(MARKER));
}

function failureBody(result) {
  const missingList = result.missing.map((field) => `- ${field}`).join("\n");
  const visualFiles = result.visualFiles.length
    ? `\n\nVisual files detected:\n${result.visualFiles.map((file) => `- \`${file}\``).join("\n")}`
    : "";

  return [
    "The PR Policy check is blocking this PR because required template information is missing.",
    "",
    "Please update the PR description with:",
    missingList,
    visualFiles,
    "",
    "Screenshots or video are required for UI, UX, settings, onboarding, overlay, menu bar, or visual behavior changes. If this PR has no visual changes, check the no-visual-change box in the template.",
    "",
    `If this remains incomplete for ${HOURS_BEFORE_CLOSE} hours after opening, the PR may be closed.`,
  ].join("\n");
}

async function enforceOne(context, pr, { closeExpired, failOnInvalid, warningComment }) {
  const files = await changedFiles(context, pr.number);
  const result = validatePullRequest({ body: pr.body ?? "", changedFiles: files });

  if (result.ok) {
    await removeLabel(context, pr.number, LABELS.template.name);
    await removeLabel(context, pr.number, LABELS.screenshots.name);
    return true;
  }

  const labelsToAdd = [];
  if (result.missing.some((field) => field !== "Screenshots / Video")) {
    labelsToAdd.push(LABELS.template.name);
  }
  if (result.missing.includes("Screenshots / Video")) {
    labelsToAdd.push(LABELS.screenshots.name);
  }

  warningComment ??= await existingWarningComment(context, pr.number);
  await addLabels(context, pr.number, labelsToAdd);
  await upsertIssueComment(context, pr.number, MARKER, failureBody(result));

  const expired =
    !pr.draft &&
    warningComment?.created_at &&
    hoursSince(warningComment.created_at) >= HOURS_BEFORE_CLOSE;
  if (closeExpired && expired) {
    await githubRequest("PATCH", `/repos/${context.owner}/${context.repo}/pulls/${pr.number}`, {
      state: "closed",
    });
    await upsertIssueComment(
      context,
      pr.number,
      MARKER,
      [
        "This PR has been closed because it still does not follow the required PR template after the 48-hour correction window.",
        "",
        "Please open a new PR with the required description, related issue or accepted Discussion, testing notes, and screenshot/video evidence when applicable.",
      ].join("\n"),
    );
  }

  if (failOnInvalid) {
    console.error(`PR #${pr.number} is missing: ${result.missing.join(", ")}`);
    process.exitCode = 1;
  }

  return false;
}

async function openPullRequests(context) {
  return paginate(`/repos/${context.owner}/${context.repo}/pulls?state=open`);
}

async function main() {
  const context = repoContext();
  await Promise.all(Object.values(LABELS).map((label) => ensureLabel(context, label)));

  const eventName = process.env.GITHUB_EVENT_NAME;

  if (eventName === "schedule" || eventName === "workflow_dispatch") {
    const pulls = await openPullRequests(context);
    for (const pr of pulls) {
      const warningComment = await existingWarningComment(context, pr.number);
      if (!warningComment) continue;

      await enforceOne(context, pr, {
        closeExpired: true,
        failOnInvalid: false,
        warningComment,
      });
    }
    return;
  }

  const event = eventPayload();
  const warningComment = await existingWarningComment(context, event.pull_request.number);

  if (event.action !== "opened" && !warningComment) {
    return;
  }

  await enforceOne(context, event.pull_request, {
    closeExpired: true,
    failOnInvalid: true,
    warningComment,
  });
}

await main();
