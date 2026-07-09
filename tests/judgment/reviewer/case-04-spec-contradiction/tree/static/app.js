// QuickList client behaviour: the "Open only" filter (J-03).
document.addEventListener("DOMContentLoaded", () => {
  const toggle = document.getElementById("open-only");
  if (!toggle) return;
  toggle.addEventListener("change", () => {
    document.querySelectorAll("li.item.done").forEach((row) => {
      row.style.display = toggle.checked ? "none" : "";
    });
  });
});

// Quantity update validation (J-04): block bad values before they reach the server.
document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("form.qty-form").forEach((form) => {
    form.addEventListener("submit", (event) => {
      const qty = form.querySelector('input[name="qty"]').value.trim();
      if (!/^[0-9]+$/.test(qty) || Number(qty) < 1) {
        alert("Quantity must be a whole number of at least 1.");
        event.preventDefault();
      }
    });
  });
});
