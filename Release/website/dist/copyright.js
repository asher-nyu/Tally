const year = String(new Date().getFullYear());

document.querySelectorAll("[data-copyright-year]").forEach((element) => {
  element.textContent = year;
});
