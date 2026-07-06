const statusEl = document.getElementById("status");
const rowsEl = document.getElementById("rows");
const jsonEl = document.getElementById("json");
const refreshButton = document.getElementById("refresh");

function taskTitle(process) {
  return (process.tasks || []).map((task) => task.title).filter(Boolean).join(" | ");
}

function taskTabIds(process) {
  return [...new Set((process.tasks || []).map((task) => task.tabId).filter(Number.isFinite))];
}

async function collect() {
  if (!chrome.processes?.getProcessInfo) {
    throw new Error("chrome.processes is unavailable in this Chrome build/profile.");
  }

  const [processesById, tabs] = await Promise.all([
    chrome.processes.getProcessInfo([], true),
    chrome.tabs.query({})
  ]);

  const tabsById = new Map(tabs.map((tab) => [tab.id, tab]));
  const processes = Object.values(processesById)
    .map((process) => {
      const tabIds = taskTabIds(process);
      const tab = tabIds.map((id) => tabsById.get(id)).find(Boolean);

      return {
        osProcessId: process.osProcessId,
        chromeProcessId: process.id,
        type: process.type,
        cpu: process.cpu ?? 0,
        network: process.network,
        privateMemory: process.privateMemory,
        jsMemoryUsed: process.jsMemoryUsed,
        taskTitle: taskTitle(process),
        tabIds,
        tabTitle: tab?.title,
        tabUrl: tab?.url
      };
    })
    .sort((a, b) => (b.cpu || 0) - (a.cpu || 0));

  return {
    collectedAt: new Date().toISOString(),
    processes
  };
}

function render(payload) {
  rowsEl.replaceChildren();
  jsonEl.textContent = JSON.stringify(payload, null, 2);

  for (const process of payload.processes) {
    const row = document.createElement("tr");
    const title = process.taskTitle || process.tabTitle || "";
    const cells = [
      process.osProcessId ?? "",
      Number(process.cpu || 0).toFixed(1),
      process.type || "",
      title,
      process.tabUrl || ""
    ];

    for (const value of cells) {
      const cell = document.createElement("td");
      cell.textContent = String(value);
      if (value === process.tabUrl) cell.className = "url";
      row.appendChild(cell);
    }

    rowsEl.appendChild(row);
  }
}

async function refresh() {
  statusEl.textContent = "Loading...";
  try {
    const payload = await collect();
    render(payload);
    statusEl.textContent = `${payload.processes.length} processes collected.`;
  } catch (error) {
    rowsEl.replaceChildren();
    jsonEl.textContent = "";
    statusEl.textContent = error.message;
  }
}

refreshButton.addEventListener("click", refresh);
refresh();
