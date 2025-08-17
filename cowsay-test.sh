#!/bin/bash

# Frase di prova
MESSAGE="Hello from cowsay!"

# Ottieni lista di personaggi
for COW in $(cowsay -l | tail -n +2 | tr ' ' '\n'); do
    echo "------------------------------------------"
    echo "Personaggio: $COW"
    echo "------------------------------------------"
    cowsay -f "$COW" "$MESSAGE"
    echo
    # Aspetta un input per passare al successivo
    read -p "Premi Invio per continuare..."
done
