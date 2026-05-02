# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "qr-creator", to: "qr-creator.js", preload: false
pin "mlkem", to: "mlkem.js", preload: false
pin "mlkem_core", to: "mlkem_core.js", preload: false
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/modules", under: "modules"
pin_all_from "app/javascript/utils", under: "utils"
