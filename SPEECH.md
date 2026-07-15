# Presenter speech — walking a customer through the offline procedure

Teleprompter script for presenting [QUICKSTART.md](./QUICKSTART.md) live. Each block
below maps to a section of the guide, so you can scroll to whatever you're showing on
screen. It's written to be **spoken, not read** — natural phrasing, first person, plain
language. Pause where it feels right; the brackets are stage directions, not lines to
read aloud.

Full read-through is roughly 10–12 minutes at a normal pace.

---

## Opening (before you share the guide)

Thanks everyone. What I want to do today is walk you through exactly how we'll run
Microsoft's SAP configuration checks in your environment — and I want to be upfront
about the one thing I know is on everyone's mind, which is: does this touch our SAP
production servers? So I'll answer that early, and then we'll go step by step. Please
stop me at any point — this is meant to be a conversation, not a lecture.

---

## Background — why this documentation exists

So, a bit of context on why we put this guide together. Microsoft has a testing
framework that inspects an SAP system and checks it against our recommended best
practices for running SAP on Azure. Normally it just downloads what it needs from the
internet as it runs. Your environment doesn't work that way — and that's by design, for
good security reasons. Your management server has no internet access. So the standard
instructions simply don't apply. This guide is our answer to that: it's the same checks,
repackaged so the whole thing can run completely offline. Everything the tool needs gets
prepared once, on a machine that does have internet, and then carried in.

---

## Does anything get installed on the SAP servers?

Let me answer the big question right away, because it shapes everything else. The short
answer is: **no — nothing gets installed on your SAP servers.** The checks are
read-only. We log into each SAP server over SSH, we read configuration — operating
system settings, SAP parameters, how the disks and filesystems are laid out — and that's
it. We don't install packages, we don't restart services, we don't change a single
setting. All of the tooling lives on the jump server, not on the SAP hosts. We tested
this specifically, and it holds true even with the older Python that ships on your SAP
servers. So you can think of this as looking, never touching.

---

## The environment

Here's the picture of what we're working with. [Point at the diagram.] On one side you
have your jump server — that's the machine we actually run everything from. It has no
internet and no Azure portal access, and it reaches your SAP servers over your private
ExpressRoute connection. On the other side are the SAP servers themselves, also with no
internet. And then there's your laptop, which does have internet — that's where we do
the one-time preparation. So the flow is simple: the laptop prepares a bundle, we carry
that bundle to the jump server, and the jump server does the read-only checks against the
SAP servers. Nothing in this picture needs to be opened up to the internet.

---

## One decision before starting: can the Azure checks run?

There's one decision we should make up front, because it affects what the final report
looks like. The framework runs two kinds of checks. The first kind reads the operating
system and SAP configuration — those run entirely over SSH and always work. The second
kind looks at Azure infrastructure details — things like the VM size, the disk
performance tier, accelerated networking. Those need to talk to Azure directly. In a
fully offline setup, that second group can't run, and that's completely fine — I'll show
you how it shows up in the report so nobody misreads it later. If you do want that Azure
coverage, there's a path for it, and we can decide that together. But it's not required
to get real value out of this.

---

## Where each step runs

One quick orientation point that'll make the rest easy to follow. Every step in this
guide is tagged with where it runs — either on your internet laptop, or on the jump
server. The laptop does the preparation; the jump server does the actual work. If you
keep those two roles straight in your head, the whole sequence makes sense. I'll call out
which machine we're on as we go.

---

## Step 1 — Prerequisites on the jump server

Alright, step one, and this is on the jump server. We're just confirming a couple of
basics are in place — a recent Python and the git tool. On many locked-down servers the
command to install these will simply time out, because the server can't reach the update
servers. And that's okay — it's actually expected in an environment like yours. If that
happens, we don't fight it; we just carry those pieces in with the bundle instead, and
install them offline a little later. So nothing to worry about if this step doesn't go
perfectly the first time.

---

## Step 2 — Download the bundle (and WSL on Windows)

Step two moves us over to your internet laptop, and this is where we build the bundle —
the single package with everything the offline server will need. Now, these commands run
in a Linux environment. If your laptop is Windows, don't worry — there's a one-time setup
to get a small Linux environment inside Windows, called WSL. It's literally one command
in PowerShell, run as administrator, and a restart. I've put the exact steps and the
official Microsoft link right in the guide, so it's very much paint-by-numbers. One
thing to flag: on a heavily managed corporate laptop, that feature is sometimes turned
off by policy — if that's the case, we'll just loop in your IT team, or use any Linux
machine you already have. Once we're in that Linux shell, the guide's commands download
the framework, all its dependencies, and the pieces the jump server needs, and wrap them
into one file with a fingerprint so we can verify it transferred cleanly.

---

## Step 3 — Transfer the bundle to the jump server

Step three is the hand-off, and it's the simplest one. We take that one bundle file and
copy it from the laptop to the jump server. After it lands, we check the fingerprint on
both sides to make sure it arrived intact — same number on both ends, and we know nothing
got corrupted along the way. That's it.

---

## Step 4 — Install the framework on the jump server (offline)

Now we're on the jump server for step four, and this is where the offline magic happens.
Everything we carried in gets installed locally — no internet involved at all. We unpack
the bundle, install the framework and its dependencies from the files we brought, and
apply a small set of fixes we've already validated so the checks run smoothly against
your environment. When this finishes, the jump server has everything it needs, and it
never once reached out to the internet.

---

## Step 5 — Python on the SAP servers (normally skipped)

Step five — and I'm going to tell you right now, we almost certainly skip this one. This
is only here as a fallback. Because of the way we packaged things, the checks work with
the Python that's already on your SAP servers, so we don't need to install anything
there. The only reason you'd ever touch this step is a rare edge case, and we'd talk
about it first. For today, treat it as: read the heading, move on.

---

## Step 6 — Describe the SAP system (workspace)

Step six is where we describe your SAP landscape to the tool. Think of it as filling in a
short form. There are four small pieces to it — a folder, and three files inside it —
and I'll walk through each one. Nothing here is guesswork; you're really just
transcribing what you already know about your own systems.

### 6.1 — Create the workspace folder

First we make a folder that represents this specific SAP system. The name follows a
simple convention so it's easy to tell environments apart later — think environment,
region, and the system ID. The one thing that matters is that this folder name matches
what we set in the config file in the next step. We'll keep them in sync.

### 6.2 — hosts.yaml: the servers to check

Next, the list of servers. This file is where we put each SAP server we want to check —
its address, how we connect, and which role it plays, like database or application. It
already includes one line that points the tool at the server's own Python, which is part
of what lets us run without installing anything on the SAP side. So we just fill in your
server names and addresses, and we're set.

### 6.3 — sap-parameters.yaml: what the system looks like

Then a few facts about the SAP system itself — things like the system ID and a couple of
attributes about how it's deployed. It's short. This gives the checks the context they
need to know what "good" looks like for your particular setup.

### 6.4 — Credentials: how we log into the servers

And last, how the jump server authenticates to the SAP servers. This is the part your
security team will care most about, so we use whatever approach they're most comfortable
with — the guide lays out the options. The key point I want to make: these are read-only
logins used only to inspect configuration, and we handle the credentials the way your
policies require.

---

## Step 7 — Configure, and authenticate if applicable

Step seven is the final bit of setup, and it's short — two small parts.

### 7a — Edit vars.yaml: two lines

The first part is a small file where we set just two things: the type of check we're
running, and the name of the system folder we created in the last step. That's genuinely
it — two lines — and then the core run is ready to go.

### 7b — Azure authentication (only if applicable)

The second part is optional, and it only comes into play if we decided earlier to include
the Azure checks and the jump server actually has a route to Azure. In a fully offline
run — which is our case — we simply skip this, and the guide already makes the tool handle
that gracefully. So for us, step seven really is just those two lines.

---

## Step 8 — Run

And now, step eight — we run it. This is on the jump server, and it's three commands.
It kicks off all the checks against every server we listed, it takes a few minutes, and
it's completely read-only the entire time. You'll see it work through each server and
each category of check. When it's done, it writes out a report. If you happen to see a
harmless message about telemetry at the very end, ignore it — that's after the report is
already written.

---

## Step 9 — Collect the report

Last step — we collect the report. We copy the HTML file back to your laptop and open it
in a browser. And then there are two things I want to say about reading it.

### Reading the report in the offline scenario

This is the part I really want to set expectations on, so nobody misreads it. The report
comes in two halves. The operating-system and SAP configuration checks — that's the bulk
of it — ran completely, and those are real results you can act on. The Azure
infrastructure checks, because we ran offline, show up as errors or as "not available."
**That is expected. It is not a broken report and it is not a problem with your servers**
— those checks were simply out of scope for an offline run. A couple of the HANA storage
checks fall into that Azure group too, so you'll see those as "not available" as well.

### Where the value is

So where's the value in all this? The half that ran is the heart of a configuration
review — it's exactly the settings that most often cause SAP-on-Azure support issues, and
we validated all of it directly against your servers. The other half — the Azure
infrastructure side — can be confirmed in minutes by someone with portal access, or by
enabling that Azure path on the jump server if you want the tool to pull it directly. So
the way to think about it: today we complete the OS and SAP half end to end, and we close
the Azure half separately. I'll include a short scope note with the report so anyone
reading it later understands exactly that.

---

## Closing

So that's the whole flow — prepare once on the laptop, carry it in, run read-only checks
from the jump server, and share the report. The headline I want to leave you with:
nothing gets installed or changed on your SAP servers, and nothing here needs internet
access opened up. Let's get into it — and again, stop me with questions at any point.
