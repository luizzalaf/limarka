# coding: utf-8
require "thor"
require 'yaml'
require 'colorize'
require 'open3'
require 'fileutils'
require 'bibtex'


module Limarka

  # Essa class é responsável por ser a abstração de converter o arquivo
  # em Markdown para Latex.
  class Conversor
    # o trabalho
    attr_accessor :t
    # opções de execução
    # @see Cli
    attr_accessor :options
    attr_accessor :pretextual_tex
    attr_accessor :postextual_tex
    attr_accessor :texto_tex
    attr_accessor :txt
    attr_accessor :usa_pdftotext

    # @param trabalho [Trabalho]
    def initialize(trabalho, options)
      self.t = trabalho
      self.options = options
      self.usa_pdftotext = true
    end


    ## Converte o trabalho para Latex
    def convert()
      FileUtils.mkdir_p(options[:output_dir])

      # A invocação de pandoc passando parâmetro como --before-body necessita
      # de ser realizado através de arquivos, portanto, serão criados arquivos
      # temporários para sua execução
      pretextual_tempfile = Tempfile.new('pretextual')
      postextual_tempfile = Tempfile.new('postextual')
      begin
        pretextual(pretextual_tempfile)
        postextual(postextual_tempfile)
        textual(pretextual_tempfile,postextual_tempfile)

        ensure
          pretextual_tempfile.close
          pretextual_tempfile.unlink
          postextual_tempfile.close
          postextual_tempfile.unlink
      end
    end


    ## Compila tex_file no diretorio atual, retorna o conteudo somente texto do PDF
    def compila
      Dir.chdir(options[:output_dir]) do
        basename = File.basename(texto_tex_file, '.tex')
        if system ("whereis texliveonfly")
          system "texliveonfly -c xelatex -f #{basename}",  :out=>'xxx-texliveonfly-std.txt'
        end
        system "latexmk --quiet --xelatex -f #{basename}",  :out=>'xxx-latexmk-std.txt', :err=>'xxx-latexmk-erros.txt'
        if (usa_pdftotext) then
          system "pdftotext -enc UTF-8 #{basename}.pdf"
          # Comando sed para corrigir junção do fi (ligatures)
          # https://superuser.com/questions/220363/cleaning-up-pdftotext-font-issues/231637#231637
          system "sed -i -e 's/ﬃ/ffi/g' -e 's/ﬁ/fi/g' -e 's/ﬀ/ff/g' -e 's/ﬂ/fl/g' -e 's/ﬄ/ffl/g' #{basename}.txt"
          File.open("#{basename}.txt", 'r') {|f| @txt = f.read}
        end
      end
    end

    def hash_to_yaml(h)
      s = StringIO.new
      s << h.to_yaml
      s << "---\n\n"
      s.string
    end



    PRETEXTUAL = "templates/pretextual.tex"

    # Escreve no arquivo o conteúdo gerado referente ao pretextual do documento.
    # @param tempfile arquivo onde será escrito
    def pretextual(tempfile)
      s = StringIO.new
      necessita_de_arquivo_de_texto = ["errata"]
      ["folha_de_rosto", "errata", "folha_de_aprovacao", "dedicatoria", "agradecimentos",
      "epigrafe", "resumo", "abstract", "lista_ilustracoes", "lista_tabelas",
      "lista_siglas", "lista_simbolos", "sumario"].each_with_index do |secao,indice|
        template = "pretextual#{indice+1}-#{secao}"
        Open3.popen3("pandoc -f #{@t.formato} \"--data-dir=#{options[:templates_dir]}\" --template=#{template} -t latex --filter #{pandoc_abnt_path}") {|stdin, stdout, stderr, wait_thr|
          stdin.write(hash_to_yaml(t.configuracao))
          stdin.write("\n")
          if t.errata? and necessita_de_arquivo_de_texto.include?(secao) then
            arquivo_de_entrada = "#{secao}.md"
            conteudo = File.read(arquivo_de_entrada)
            stdin.write(conteudo)
          end
          stdin.close
          s << stdout.read
          exit_status = wait_thr.value # Process::Status object returned.
          if(exit_status!=0) then puts ("Erro: " + stderr.read).red end
        }
      end
      @pretextual_tex = s.string
      File.open(tempfile, 'w') { |file| file.write(pretextual_tex) }
#      puts "#{PRETEXTUAL} criado".green
    end

    POSTEXTUAL = "templates/postextual.tex"
    # Escreve no arquivo o conteúdo gerado referente ao pós-textual do documento.
    # @param tempfile arquivo onde será escrito
    def postextual(tempfile)
      # Referências (obrigatório)
      # Glossário (opcional)
      # Apêndice (opcional)
      # Anexo (opcional)
      # Índice (opcional)

      s = StringIO.new

      s << secao_referencias
      s << secao_glossario
      s << secao_apendices
      s << secao_anexos
      s << secao_indice

      cria_xxx_referencias

      @postextual_tex = s.string
      File.open(tempfile, 'w') { |file| file.write(postextual_tex) }
    end

    # Cria arquivo temporário de referencias.
    #
    # Separa o título em subtítulo quando contém `:`.
    def cria_xxx_referencias
      referencias_tempfile = Tempfile.new('referencias')
      File.open(referencias_tempfile, 'w') {|file| file.write(t.referencias)}
      b = BibTeX.open(referencias_tempfile.path)
      b.each do |entry|
        if entry.title.include?(':') then
          s = entry.title.split(':')
          if entry.title.start_with?("{") and entry.title.end_with?("}") then
            s[0] = s[0][1..-1] # remove {
            s[1] = s[1][1..-1] # remove }
          end
          entry['title'] = s[0].strip
          entry['subtitle'] = s[1].strip
        end
      end

      b.save_to referencias_bib_file
    end

    def secao_referencias
      secao("postextual1-referencias", false, t.referencias)
    end

    def secao_apendices
      secao("postextual3-apendices", t.apendices?, t.apendices)
    end

    def secao_anexos
      secao("postextual4-anexos", t.anexos?, t.anexos)
    end

    # @note Ainda não implementado
    def secao_glossario
    end

    # @note Ainda não implementado
    def secao_indice
    end

    def filtros_lua
      result = ""
      if options[:filtros_lua]
        result = options[:filtros_lua].reduce("") { |cmd, filtro| "#{cmd} --lua-filter #{filtro}" }
      end
      result
    end

    def filtros
      result = ""
      if options[:filtros]
        result = options[:filtros].reduce("") { |cmd, filtro| "#{cmd} --filter #{filtro}" }
      end
      result
    end

    def textual(pretextual_tempfile, postextual_tempfile)
      valida_yaml
      Open3.popen3("pandoc -f #{@t.formato} -t latex -s \"--data-dir=#{options[:templates_dir]}\" --template=trabalho-academico --top-level-division=chapter --include-before-body=#{pretextual_tempfile.path}  --include-after-body=#{postextual_tempfile.path} #{filtros_lua} #{filtros} --filter #{pandoc_abnt_path}") {|stdin, stdout, stderr, wait_thr|
        stdin.write(File.read(options[:templates_dir] + '/templates/configuracao-tecnica.yaml'))
        stdin.write("\n")
        stdin.write(hash_to_yaml(t.configuracao))
        stdin.write("\n")
        stdin.write(t.texto)
        stdin.close
        @texto_tex = stdout.read
        exit_status = wait_thr.value # Process::Status object returned.
        if(exit_status!=0) then puts ("Erro: " + stderr.read).red end
      }
      File.open(texto_tex_file, 'w')  { |f| f.write(@texto_tex)}
    end

    def pretextual_tex_file
      "#{options[:output_dir]}/xxx-pretextual.tex"
    end
    def postextual_tex_file
      "#{options[:output_dir]}/xxx-postextual.tex"
    end

    def texto_tex_file
      "#{options[:output_dir]}/#{Conversor.tex_file}"
    end
    def pdf_file
      texto_tex_file.sub('.tex','.pdf')
    end

    def referencias_bib_file
      "#{options[:output_dir]}/xxx-referencias.bib"
    end

    def valida_yaml
      # não faz nada por enquanto
    end

    def self.tex_file()
      "xxx-trabalho-academico.tex"
    end

    private

    # Utilizado para gerar seções específicas do documento
    def secao(template, condicao_para_conteudo, conteudo_externo)
      s = StringIO.new

      Open3.popen3("pandoc -f #{@t.formato} \"--data-dir=#{options[:templates_dir]}\" --template=#{template} --top-level-division=chapter -t latex --filter #{pandoc_abnt_path}") {|stdin, stdout, stderr, wait_thr|
        stdin.write(hash_to_yaml(t.configuracao))
        stdin.write("\n")
        if (condicao_para_conteudo) then
          stdin.write(conteudo_externo)
          stdin.write("\n")
        end
        stdin.close
        s << stdout.read
        exit_status = wait_thr.value # Process::Status object returned.
        if(exit_status!=0) then puts ("Erro: " + stderr.read).red end
      }
      s.string
    end

    def pandoc_abnt_path
      ENV["PANDOC_ABNT_BAT"] or "pandoc_abnt"
    end

  end
end
