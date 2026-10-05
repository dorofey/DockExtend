const panel = document.querySelector('#customizePanel');
const backdrop = document.querySelector('#panelBackdrop');
const openButtons = [document.querySelector('#customizeTop'), document.querySelector('#addWidget')];
const closeButton = document.querySelector('#closePanel');
const saveButton = document.querySelector('#saveButton');
const previewLabel = document.querySelector('#previewLabel');
const displayChoices = document.querySelectorAll('.display-choice');

function setPanel(open) {
  panel.classList.toggle('open', open);
  backdrop.classList.toggle('open', open);
  panel.setAttribute('aria-hidden', String(!open));
  if (open) closeButton.focus();
}

openButtons.forEach((button) => button.addEventListener('click', () => setPanel(true)));
closeButton.addEventListener('click', () => setPanel(false));
backdrop.addEventListener('click', () => setPanel(false));
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') setPanel(false); });

document.querySelectorAll('.mode-button').forEach((button) => {
  button.addEventListener('click', () => {
    document.querySelectorAll('.mode-button').forEach((item) => item.classList.remove('selected'));
    button.classList.add('selected');
    previewLabel.textContent = button.dataset.mode === 'macos' ? 'Classic arrangement' : 'Custom arrangement';
    document.querySelector('#dock').classList.toggle('classic', button.dataset.mode === 'macos');
  });
});

document.querySelectorAll('.option').forEach((option) => option.addEventListener('click', () => {
  option.classList.toggle('active');
  option.querySelector('.check').textContent = option.classList.contains('active') ? '✓' : '+';
}));

displayChoices.forEach((choice) => choice.addEventListener('click', () => {
  displayChoices.forEach((item) => item.classList.remove('selected'));
  choice.classList.add('selected');
  const dock = document.querySelector('#dock');
  const compact = choice.dataset.display === 'compact';
  dock.classList.toggle('compact', compact);
  dock.dataset.display = choice.dataset.display;
}));

saveButton.addEventListener('click', () => {
  saveButton.textContent = 'Arrangement saved';
  setTimeout(() => setPanel(false), 650);
  setTimeout(() => { saveButton.textContent = 'Save arrangement'; }, 1000);
});
