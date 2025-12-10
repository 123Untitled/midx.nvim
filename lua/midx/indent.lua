
-- indent.lua
  -- Fonction d'indentation automatique pour MIDILang

  local M = {}

  -- Vérifie si une ligne contient un identifiant (commence par une lettre)
  local function has_identifier(line)
    return line:match("^%s*[a-zA-Z][a-zA-Z0-9_]*%s*$") ~= nil
  end

  -- Vérifie si une ligne contient un paramètre (commence par :)
  local function has_parameter(line)
    return line:match("^%s*:[a-z][a-z]") ~= nil
  end

  -- Vérifie si une ligne est une séquence (ne commence pas par : ou identifiant)
  -- et contient des valeurs/opérateurs
  local function is_sequence(line)
    local trimmed = line:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
      return false
    end

    -- Commence par un chiffre, %, ^, \, (, |, ou &
    return trimmed:match("^[0-9%%^\\(|&]") ~= nil
  end

  -- Vérifie si une ligne contient un point-virgule (fin de bloc)
  local function has_semicolon(line)
    return line:match(";") ~= nil
  end

  -- Vérifie si une ligne est un commentaire (commence par ~)
  local function is_comment(line)
    return line:match("^%s*~") ~= nil
  end

  -- Vérifie si une ligne est vide
  local function is_empty(line)
    return line:match("^%s*$") ~= nil
  end

  -- Obtient l'indentation d'une ligne (nombre de caractères de whitespace au début)
  local function get_line_indent(line)
    local indent = line:match("^(%s*)")
    return #indent
  end

  -- Calcule l'indentation pour une ligne donnée
  function M.get_indent(lnum)
    -- Ligne courante
    local line = vim.fn.getline(lnum)

    -- Si c'est un commentaire ou une ligne vide, garde l'indentation actuelle
    if is_comment(line) or is_empty(line) then
      return -1  -- Garde l'indentation actuelle
    end

    -- Cherche la ligne précédente non-vide et non-commentaire
    local prev_lnum = lnum - 1
    local prev_line = ""

    while prev_lnum > 0 do
      prev_line = vim.fn.getline(prev_lnum)
      if not is_empty(prev_line) and not is_comment(prev_line) then
        break
      end
      prev_lnum = prev_lnum - 1
    end

    -- Si pas de ligne précédente, pas d'indentation
    if prev_lnum == 0 then
      return 0
    end

    -- Si la ligne précédente a un point-virgule, retour à l'indentation 0
    if has_semicolon(prev_line) then
      return 0
    end

    local shiftwidth = vim.fn.shiftwidth()

    -- Si la ligne courante est une séquence
    if is_sequence(line) then
      -- Cherche le dernier paramètre avant cette ligne
      local search_lnum = lnum - 1
      while search_lnum > 0 do
        local search_line = vim.fn.getline(search_lnum)

        -- Si on trouve un point-virgule, on arrête (nouveau bloc)
        if has_semicolon(search_line) then
          return 0
        end

        -- Si on trouve un paramètre, on indente de 2 niveaux
        if has_parameter(search_line) then
          -- Vérifie si c'est un identifiant avant le paramètre
          local id_lnum = search_lnum - 1
          while id_lnum > 0 do
            local id_line = vim.fn.getline(id_lnum)
            if has_semicolon(id_line) then
              break
            end
            if has_identifier(id_line) then
              return shiftwidth * 2  -- 2 niveaux d'indentation
            end
            if not is_empty(id_line) and not is_comment(id_line) then
              break
            end
            id_lnum = id_lnum - 1
          end
          -- Pas d'identifiant trouvé, juste 1 niveau
          return shiftwidth
        end

        -- Si on trouve une autre séquence, on garde la même indentation
        if is_sequence(search_line) then
          return get_line_indent(search_line)
        end

        search_lnum = search_lnum - 1
      end

      return 0
    end

    -- Si la ligne courante est un paramètre
    if has_parameter(line) then
      -- Cherche le dernier identifiant avant cette ligne
      local search_lnum = lnum - 1
      while search_lnum > 0 do
        local search_line = vim.fn.getline(search_lnum)

        -- Si on trouve un point-virgule, on arrête (nouveau bloc)
        if has_semicolon(search_line) then
          return 0
        end

        -- Si on trouve un identifiant, on indente
        if has_identifier(search_line) then
          return shiftwidth
        end

        search_lnum = search_lnum - 1
      end

      -- Pas d'identifiant trouvé, pas d'indentation
      return 0
    end

    -- Pour les identifiants ou autres lignes, pas d'indentation
    return 0
  end

  -- Configure l'indentation pour le buffer courant
  function M.setup()
    vim.bo.indentexpr = "v:lua.require'midx.indent'.get_indent(v:lnum)"
    vim.bo.autoindent = true
  end

  return M
