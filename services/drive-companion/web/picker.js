"use strict";

const codeInput = document.getElementById("pair-code");
if (codeInput) {
  codeInput.addEventListener("input", () => {
    codeInput.value = codeInput.value.replace(/[a-z]/g, (letter) => letter.toUpperCase());
  });
}

const pickerPage = document.getElementById("picker-page");
if (pickerPage) {
  const openButton = document.getElementById("open-picker");
  const confirmButton = document.getElementById("confirm-selection");
  const review = document.getElementById("selection-review");
  const reviewTitle = document.getElementById("review-title");
  const fileList = document.getElementById("selected-files");
  const status = document.getElementById("picker-status");
  const maximumFiles = 100;
  const identifier = /^[A-Za-z0-9_-]{1,256}$/;
  let selected = [];
  let activePicker;
  let pickerLibrary;

  function updateStatus(message, error = false) {
    status.textContent = message;
    status.hidden = !message;
    status.dataset.error = String(error);
  }

  function loadPicker() {
    if (!pickerLibrary) {
      pickerLibrary = new Promise((resolve, reject) => {
        if (window.google?.picker) {
          resolve(window.google.picker);
          return;
        }
        const script = document.createElement("script");
        const timeout = window.setTimeout(fail, 15000);

        function fail() {
          window.clearTimeout(timeout);
          script.remove();
          reject(new Error("picker_unavailable"));
        }

        function loadModule() {
          if (typeof window.gapi?.load !== "function") {
            fail();
            return;
          }
          window.gapi.load("picker", {
            callback: () => {
              if (!window.google?.picker) {
                fail();
                return;
              }
              window.clearTimeout(timeout);
              resolve(window.google.picker);
            },
            onerror: fail,
            timeout: 10000,
            ontimeout: fail,
          });
        }

        if (window.gapi?.load) {
          loadModule();
        } else {
          script.src = "https://apis.google.com/js/api.js";
          script.async = true;
          script.onload = loadModule;
          script.onerror = fail;
          document.head.append(script);
        }
      }).catch((error) => {
        pickerLibrary = undefined;
        throw error;
      });
    }
    return pickerLibrary;
  }

  function readableError(error) {
    switch (error) {
      case "invalid_selection":
        return "Choose individual videos, photos, or subtitle files and try again.";
      case "unsupported_media":
        return "Choose supported videos, JPEG, PNG, WebP, HEIC or HEIF photos up to 64 MiB, or SRT/VTT subtitles up to 2 MiB.";
      case "invalid_filename":
        return "One file has a name MediaVault can’t use. Rename it in Google Drive or leave it out.";
      case "name_collision":
        return "Two selected files have the same name. Rename one in Google Drive or select only one of them.";
      case "selection_unavailable":
        return "One or more files couldn’t be opened. Check their download permissions in Google Drive or choose other files.";
      case "authorization_expired":
        return "This pairing expired. Get a new code on your TV and start again here.";
      case "picker_unavailable":
        return "Google Drive couldn’t open. Check your connection and try again.";
      default:
        return "MediaVault couldn’t complete this step. Try again or get a new code on your TV.";
    }
  }

  async function requestJSON(path, options = {}) {
    const response = await fetch(path, {
      ...options,
      credentials: "same-origin",
      cache: "no-store",
      redirect: "error",
      headers: { Accept: "application/json", ...options.headers },
    });
    const payload = await response.json().catch(() => null);
    if (!response.ok || !payload) {
      const error = payload?.error ?? ([401, 403, 410].includes(response.status) ? "authorization_expired" : "");
      throw new Error(error);
    }
    return payload;
  }

  function showSelection(files) {
    selected = files;
    fileList.replaceChildren(...files.map((file) => {
      const item = document.createElement("li");
      item.textContent = file.name;
      return item;
    }));
    review.hidden = false;
    reviewTitle.focus();
    updateStatus(files.length === 1 ? "1 file selected." : `${files.length} files selected.`);
  }

  function handlePickerEvent(picker, response) {
    const action = response[picker.Response.ACTION];
    if (action !== picker.Action.PICKED && action !== picker.Action.CANCEL) return;
    const closedPicker = activePicker;
    activePicker = undefined;
    if (typeof closedPicker?.dispose === "function") closedPicker.dispose();
    openButton.disabled = false;
    if (action === picker.Action.CANCEL) {
      updateStatus("Google Drive closed.");
      openButton.focus();
      return;
    }

    selected = [];
    review.hidden = true;
    fileList.replaceChildren();
    const documents = response[picker.Response.DOCUMENTS];
    if (!Array.isArray(documents) || !documents.length || documents.length > maximumFiles) {
      updateStatus(readableError("invalid_selection"), true);
      openButton.focus();
      return;
    }

    const files = new Map();
    for (const entry of documents) {
      const id = entry?.[picker.Document.ID];
      const pickerKey = entry?.resourceKey;
      const legacyKey = entry?.[picker.Document.RESOURCE_KEY];
      const selectedKey = pickerKey == null || pickerKey === "" ? legacyKey : pickerKey;
      const resourceKey = selectedKey == null || selectedKey === "" ? undefined : selectedKey;
      const mimeType = entry?.[picker.Document.MIME_TYPE];
      const name = entry?.[picker.Document.NAME];
      if (typeof id !== "string" || !identifier.test(id)
          || (resourceKey !== undefined && (typeof resourceKey !== "string" || !identifier.test(resourceKey)))
          || (typeof mimeType === "string" && mimeType.toLowerCase().startsWith("application/vnd.google-apps."))
          || (files.has(id) && files.get(id).resourceKey !== resourceKey)) {
        updateStatus(readableError("invalid_selection"), true);
        openButton.focus();
        return;
      }
      const title = typeof name === "string" ? name.replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, "").trim().slice(0, 140) : "";
      files.set(id, { id, resourceKey, name: title || "Selected file" });
    }
    showSelection([...files.values()]);
  }

  openButton.addEventListener("click", async () => {
    openButton.disabled = true;
    confirmButton.disabled = true;
    updateStatus("Opening Google Drive…");
    try {
      const picker = await loadPicker();
      const session = await requestJSON("/browser/session");
      if (typeof session.accessToken !== "string" || !session.accessToken
          || typeof session.pickerApiKey !== "string" || !session.pickerApiKey
          || typeof session.googleAppId !== "string" || !/^\d+$/.test(session.googleAppId)) {
        throw new Error("authorization_expired");
      }
      const files = new picker.DocsView(picker.ViewId.DOCS)
        .setIncludeFolders(true)
        .setSelectFolderEnabled(false)
        .setMode(picker.DocsViewMode.LIST);
      activePicker = new picker.PickerBuilder()
        .addView(files)
        .enableFeature(picker.Feature.MULTISELECT_ENABLED)
        .setMaxItems(maximumFiles)
        .setAppId(session.googleAppId)
        .setDeveloperKey(session.pickerApiKey)
        .setOAuthToken(session.accessToken)
        .setOrigin(window.location.origin)
        .setCallback((response) => {
          handlePickerEvent(picker, response);
          confirmButton.disabled = Boolean(activePicker);
        })
        .build();
      activePicker.setVisible(true);
      updateStatus("");
    } catch (error) {
      activePicker = undefined;
      openButton.disabled = false;
      confirmButton.disabled = false;
      updateStatus(readableError(error.message), true);
    }
  });

  confirmButton.addEventListener("click", async () => {
    if (!selected.length || activePicker) return;
    confirmButton.disabled = true;
    openButton.disabled = true;
    updateStatus("Checking your files…");
    try {
      const payload = await requestJSON("/browser/selection", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          files: selected.map(({ id, resourceKey }) => resourceKey === undefined ? { id } : { id, resourceKey }),
        }),
      });
      if (payload.ok !== true) throw new Error("invalid_selection");
      selected = [];
      window.location.replace("/pair/complete");
    } catch (error) {
      updateStatus(readableError(error.message), true);
      confirmButton.disabled = false;
      openButton.disabled = false;
    }
  });
}
