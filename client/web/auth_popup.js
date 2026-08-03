window.AuthPopup = (function() {
  let popupWindow = null;

  function openPopup(url, windowName, windowFeatures) {
    const width = 500;
    const height = 600;
    const left = Math.max(0, (window.screen.width - width) / 2);
    const top = Math.max(0, (window.screen.height - height) / 2);
    const centeredFeatures = `width=${width},height=${height},left=${left},top=${top},menubar=no,toolbar=no,status=no,location=no,resizable=yes,scrollbars=yes`;

    popupWindow = window.open(url, windowName, centeredFeatures);
    if (popupWindow) {
      popupWindow.focus();
    }
    return popupWindow;
  }

  function isPopupClosed() {
    try {
      if (!popupWindow) return true;
      return popupWindow.closed;
    } catch (e) {
      console.warn('Error checking popupWindow.closed (likely due to cross-origin redirect):', e);
      return false;
    }
  }

  function closePopup() {
    if (popupWindow && !popupWindow.closed) {
      popupWindow.close();
    }
  }

  return {
    openPopup: openPopup,
    isPopupClosed: isPopupClosed,
    closePopup: closePopup
  };
})();
