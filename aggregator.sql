DROP TABLE IF EXISTS aggregator.pred_vida_wide_data;
DROP TABLE IF EXISTS aggregator.pred_vida_wide_data_python;
DROP TABLE IF EXISTS aggregator.pred_ma_wide_data_python;
DROP TABLE IF EXISTS aggregator.pred_ifpd_wide_data_python;
DROP TABLE IF EXISTS aggregator.pred_ipa_wide_data_python;
DROP TABLE IF EXISTS aggregator.pred_ipta_wide_data_python;
DROP TABLE IF EXISTS aggregator.pred_dg_wide_data_python;
DROP TABLE IF EXISTS aggregator.pred_dit_wide_data_python;
DROP TABLE IF EXISTS aggregator.pred_dmho_wide_data_python;

/* 
   Tabela física temporária 'cap_status' para agilizar 
   o inner join da próxima query
*/
CREATE TABLE aggregator.cap_status AS
	 SELECT DISTINCT company_id, applicant_id, meta_value::text
				FROM aggregator.data_inputs
			   WHERE meta_key = 'capital_status'
				 AND ( meta_value::text = '"1"' OR meta_value::text = '"2"' OR meta_value::text = '"3"' );

        
			CREATE INDEX idx_capstatus
			          ON aggregator.cap_status( company_id, applicant_id );	
/*
	Tabela temporária 'pred_vida_ids'
	Conteúdo: company_id e applicant_id para o modelo preditivo vida
	Filtros: 
	 - status = 5 (Concluído) e 
	 - capital_status IN (1,2,5) -- cobertura de morte (agravo, recusa, aceito)
*/
-- Deletar a tabela 'pred_vida_ids' se ela existir
DROP TABLE IF EXISTS aggregator.pred_vida_ids;

-- Criar a tabela 'pred_vida_ids' com dados distintos
CREATE TABLE aggregator.pred_vida_ids AS
SELECT DISTINCT a.company_id, a.applicant_id
FROM aggregator.data_inputs AS a
INNER JOIN aggregator.cap_status AS b
    ON b.company_id = a.company_id AND b.applicant_id = a.applicant_id
WHERE a.meta_key = 'status'
 AND a.meta_value::text = '"5"';

-- Criar índice para agilizar consultas futuras
CREATE INDEX idx_ids
ON aggregator.pred_vida_ids (company_id, applicant_id);

-- Deletar a tabela 'cap_status' se ela existir
DROP TABLE IF EXISTS aggregator.cap_status;

/*
    ------------------------------------------------
    Tabela permanente 'pred_vida_proddb_occupations'
    ------------------------------------------------
    Tabela permanente para embasar reclassificação
    da ~occupation~ original à CBO/Ocupação
*/
DROP TABLE IF EXISTS aggregator.pred_vida_proddb_occupations;

-- Criação da tabela permanente
CREATE TABLE aggregator.pred_vida_proddb_occupations AS
    SELECT DISTINCT 
        d.company_id,
        d.applicant_id,
        CAST(REPLACE(d.meta_value::text, '"', '') AS VARCHAR(150)) AS raw -- Correção do tipo CHAR para VARCHAR
    FROM aggregator.data_inputs AS d
    INNER JOIN aggregator.pred_vida_ids AS ids
    ON d.company_id = ids.company_id
    AND d.applicant_id = ids.applicant_id
    WHERE d.meta_key = 'occupation';

-- Complemento da tabela para uso posterior
ALTER TABLE aggregator.pred_vida_proddb_occupations
    ADD COLUMN n_spaces INT, -- número de espaços (' ') na coluna RAW
    ADD COLUMN cbo_manual VARCHAR(30),
    ADD COLUMN cbo_luma_udw VARCHAR(6),
    ADD COLUMN cbo_gdegrp VARCHAR(255);

-- Criação do índice

/* https://www.w3resource.com/PostgreSQL/left-function.php#google_vignette

TIRAR A DUVIDA COMN O RAFA SOBRE ESTE INDEX, O ORIGINAL PÕE UM LIMITE DE raw(150), porém a função do postgres é diferente, como mostrada neste link, deveriamos usar LEFT(  RAW, 150)

CREATE INDEX: Cria um índice chamado idx_occupations nas colunas company_id, applicant_id, e nos primeiros 150 caracteres da coluna raw (usando LEFT(raw, 150)).

*/

CREATE INDEX idx_occupations
    ON aggregator.pred_vida_proddb_occupations (company_id, applicant_id, LEFT(raw, 150));

-- Normalização dos dados (remoção de acentuação, espaços reduntantes e colocação da string em caixa alta

-- Primeira etapa: TRIM e UPPER
UPDATE aggregator.pred_vida_proddb_occupations
SET raw = TRIM(UPPER(raw));

-- Segunda etapa: substituição de caracteres usando TRANSLATE e REGEXP_REPLACE
UPDATE aggregator.pred_vida_proddb_occupations
SET raw = REGEXP_REPLACE(
    TRANSLATE(raw,
        'ÃÁÂÀÊÉÈÍÇÔÓÒÕÚÜ./', 
        'AAAAEEEICOOUUU  '),
    '\.|\/', ' ', 'g');

/* Se a flag g não fosse usada, apenas a primeira ocorrência do padrão na string seria substituída. Por exemplo:

Com a flag g: 'A.B.C' se tornaria 'A B C'.
Sem a flag g: 'A.B.C' se tornaria 'A B.C'.
*/

-- Terceira etapa: definir valores nulos
UPDATE aggregator.pred_vida_proddb_occupations
SET raw = CASE
    WHEN raw = '' OR raw = 'NULL' THEN NULL
    ELSE raw
END;

/* 
   número de espaços na string 'raw' --> usado para buscas de ocupações truncadas na public_dbs.cbo_ocupacao 
   Fonte: https://stackoverflow.com/a/36998855, acesso em 06.12.2021
*/

UPDATE aggregator.pred_vida_proddb_occupations SET n_spaces = ROUND((CHAR_LENGTH(raw) - CHAR_LENGTH(REPLACE(raw, ' ', ''))) / CHAR_LENGTH(' '));

/* 
   Filtro 1: traz codigo da CBO da public_dbs.cbo_ocupacao. 
   Busca exata, ou seja, occp.raw coincide com listagem na public_dbs.cbo_ocupacao
   Query demorada... 
*/

UPDATE aggregator.pred_vida_proddb_occupations
    SET cbo_manual = cbo.codigo
FROM public_dbs.cbo_ocupacao AS cbo
    WHERE aggregator.pred_vida_proddb_occupations.raw = cbo.ocupacao;


/* 
   Filtro 2: Busca parcial da occp.raw truncada na cbo.ocupacao
   Critério: quando houver mais de uma ocupação na public_dbs.cbo_ocupacao
             correspondente ao occp.raw truncado, assumir a primeira ocorrência
             em public_dbs.cbo_ocupacao como sendo a reclassificação correta.
			 Em seguida, traz ao campo cbo_codigo o código da CBO desta imputação
             feita no passo anterior.
*/
DROP TABLE IF EXISTS aggregator.pred_vida_proddb_occupations_reclass
                   ;
        CREATE TABLE aggregator.pred_vida_proddb_occupations_reclass AS
     SELECT DISTINCT occp.raw
			         ,COUNT(occp.raw) AS n_linhas
					 ,MIN(cbo.ocupacao) AS cbo_ocupacao
                FROM aggregator.pred_vida_proddb_occupations AS occp
           LEFT JOIN public_dbs.cbo_ocupacao AS cbo
                  ON cbo.ocupacao LIKE concat(occp.raw,'%')
               WHERE occp.cbo_manual IS NULL
			     AND occp.raw IS NOT NULL
				 AND cbo.codigo IS NOT NULL
                 AND occp.n_spaces >= 2 -- registros com 3 ou mais palavras
            GROUP BY 1
            ORDER BY 1
                   ;
         ALTER TABLE aggregator.pred_vida_proddb_occupations_reclass
		  ADD COLUMN cbo_codigo VARCHAR(11)
		           ;

CREATE INDEX idx_occp_reclass
ON aggregator.pred_vida_proddb_occupations_reclass (raw, cbo_codigo);

-- Primeira atualização: Atualizando pred_vida_proddb_occupations_reclass
UPDATE aggregator.pred_vida_proddb_occupations_reclass AS rc
SET cbo_codigo = cbo.codigo
FROM public_dbs.cbo_ocupacao AS cbo
WHERE rc.cbo_ocupacao = cbo.ocupacao;

-- Segunda atualização: Atualizando pred_vida_proddb_occupations
UPDATE aggregator.pred_vida_proddb_occupations AS occp
SET cbo_manual = rc.cbo_codigo
FROM aggregator.pred_vida_proddb_occupations_reclass AS rc
WHERE occp.raw = rc.raw
  AND occp.cbo_manual IS NULL;


/* Filtro 3: Correções manuais nas exceções dos procedimentos acima... */

              UPDATE aggregator.pred_vida_proddb_occupations
				 SET cbo_manual = 
					 CASE
						  -- SEM CLASSIFICAÇÃO
						  WHEN raw LIKE '%APOSENTAD%'   THEN 'APOSENTADO' -- Aposentado não é profissão...
						  WHEN raw LIKE '%PENSIONISTA%' THEN 'APOSENTADO' -- Pensionista não é profissão...
						  WHEN raw LIKE '%DO LAR%'      THEN 'DOMESTICA'  -- Do Lar não é profissão...
						  WHEN raw LIKE '%DOMESTIC%'    THEN 'DOMESTICA'  -- Doméstica não é profissão...
						  WHEN raw LIKE '%ESTUDANT%'    THEN 'ESTUDANTE'  -- Estudante não é profissão...
						  WHEN raw LIKE '%ESTAGI%'      THEN 'ESTUDANTE'  -- Estagiário não é profissão...
						  WHEN raw LIKE '%BOLSIST%'     THEN 'ESTUDANTE'  -- Bolsista não é profissão...
						  WHEN raw LIKE 'APRENDIZ%'     THEN 'ESTUDANTE'  -- Aprendiz não é profissão...
						  -- ADMINISTRADORES
						  WHEN raw LIKE '%ADM%'       THEN '252105' -- (CBO) Administrador
						  WHEN raw LIKE 'EMPRESAR%'   THEN '252105' -- (CBO) Administrador
						  WHEN raw LIKE 'AUTONO%'     THEN '252105' -- (CBO) Administrador
						  -- AGRICULTORES
  						  WHEN raw LIKE '%AGRIC%'   OR raw LIKE '%AGROP%'  THEN '612005' -- (CBO) PRODUTOR AGRICOLA POLIVALENTE
  						  WHEN raw LIKE '%PRODUT%' AND raw LIKE '%RURAL%'  THEN '612005' -- (CBO) PRODUTOR AGRICOLA POLIVALENTE
						  -- AGRONOMOS
  						  WHEN raw LIKE '%AGRON%'  THEN '222110' -- (CBO) ENGENHEIRO AGRONOMO
						  -- ARQUITET
  						  WHEN raw LIKE '%ARQUIT%' THEN '214125' -- (CBO) ARQUITETO URBANISTA
						  -- ARTESAO
  						  WHEN raw LIKE '%ARTESA%' THEN '791130' -- (CBO) ARTESAO ESCULTOR
						  -- ATENDENTES
  						  WHEN raw LIKE '%ATEND%'  THEN '521140' -- (CBO) ATENDENTE DE LOJAS E MERCADOS
						  -- ATLETAS
  						  WHEN raw LIKE '%ATLET%'   THEN '377105' -- (CBO) ATLETA PROFISSIONAL (OUTRAS MODALIDADES)
  						  WHEN raw LIKE '%JOGADOR%' THEN '377105' -- (CBO) ATLETA PROFISSIONAL (OUTRAS MODALIDADES)
						  -- BANCARIO
  						  WHEN raw LIKE '%BANC%'   THEN '413210' -- (CBO) CAIXA DE BANCO
						  -- BOMBEIRO
  						  WHEN raw LIKE '%BOMBEIR%' THEN '031210' -- (CBO) SOLDADO BOMBEIRO MILITAR
						  -- CABELELEIRO
  						  WHEN raw LIKE '%CABEL%'  THEN '516110' -- (CBO) CABELEIREIRO
						  -- CAIXA
  						  WHEN raw LIKE '%CAIXA%'  THEN '421125' -- (CBO) OPERADOR DE CAIXA
						  -- CANTOR
  						  WHEN raw LIKE '%CANTO%' OR raw LIKE '%MUSICO%' THEN '262705' -- (CBO) MUSICO INTERPRETE CANTOR
						  -- COSTUREIRA
  						  WHEN raw LIKE '%COSTURE%' THEN '763010' -- (CBO) COSTUREIRA DE PECAS SOB ENCOMENDA
						  -- COZINHEIRO
  						  WHEN raw LIKE '%COZIN%' THEN '513205' -- (CBO) COZINHEIRO GERAL
						  -- CUIDADOR
  						  WHEN raw LIKE '%CUIDADOR%' THEN '516220' -- (CBO) CUIDADOR EM SAUDE
						  -- DENTISTA
  						  WHEN raw LIKE '%DENTIS%' OR raw LIKE '%ODONTO%' THEN '223208' -- (CBO) CIRURGIAO DENTISTA - CLINICO GERAL
						  -- ELETRICISTA
  						  WHEN raw LIKE '%ELETRICI%' AND raw LIKE '%TEC%'         THEN '313130' -- (CBO) TECNICO ELETRICISTA
  						  WHEN raw LIKE '%ELETRICI%' AND raw NOT LIKE '%TEC%'     THEN '732105' -- (CBO) ELETRICISTA DE MANUTENCAO DE LINHAS ELETRICAS, TELEFONICAS E DE COMUNICACAO DE DADOS
						  -- ENFERMEIROS
  						  WHEN raw LIKE '%ENFERM%' AND raw LIKE '%TEC%'     THEN '322205' -- (CBO) TECNICO DE ENFERMAGEM
  						  WHEN raw LIKE '%ENFERM%' AND raw NOT LIKE '%TEC%' THEN '223505' -- (CBO) ENFERMEIRO
						  -- ESTETICISTA
  						  WHEN raw LIKE '%ESTET%' THEN '322130' -- (CBO) ESTETICISTA
						  -- ESTOQUISTA
  						  WHEN raw LIKE '%ESTOQ%' THEN '414125' -- (CBO) ESTOQUISTA
						  -- FISIOTERAPEUTA
  						  WHEN raw LIKE '%FISIO%' THEN '223605' -- (CBO) FISIOTERAPEUTA GERAL
						  -- GARCOM
  						  WHEN raw LIKE '%GARCO%' THEN '513405' -- (CBO) GARCOM
						  -- JORNALISTA
  						  WHEN raw LIKE '%JORNALIS%' THEN '261125' -- (CBO) JORNALISTA
						  -- LOCUTOR
  						  WHEN raw LIKE '%LOCUTOR%' THEN '261715' -- (CBO) LOCUTOR DE MIDIAS AUDIOVISUAIS
						  -- MANICUR
  						  WHEN raw LIKE '%MANICU%' THEN '516120' -- (CBO) MANICURE
						  -- MECANICO
  						  WHEN raw LIKE '%MECANIC%' OR raw LIKE '%MEC MAN%' THEN '914405' -- (CBO) MECANICO DE MANUTENCAO DE AUTOMOVEIS, MOTOCICLETAS E VEICULOS SIMILARES
						  -- MEDICO
  						  WHEN raw LIKE '%MEDIC%' THEN '225125' -- (CBO) MEDICO CLINICO
  						  WHEN raw LIKE '%CLINIC%' AND raw LIKE '%GERAL%' THEN '225125' -- (CBO) MEDICO CLINICO
						  -- MOTORISTAS
  						  WHEN raw LIKE '%MOTORIS%' THEN '782315' -- (CBO) MOTORISTA DE TAXI
						  -- PESQUISADOR
  						  WHEN raw LIKE '%PESQUISAD%' THEN '203110' -- (CBO) PESQUISADOR EM CIENCIAS DA TERRA E MEIO AMBIENTE
						  -- PSICOLOGO
  						  WHEN raw LIKE '%PSICO%' OR raw LIKE '%PISCOL%'  THEN '251510' -- (CBO) PSICOLOGO CLINICO
						  -- FONOAUDIOLOGO
  						  WHEN raw LIKE '%FONOAUD%' THEN '223810' -- (CBO) FONOAUDIOLOGO GERAL
						  -- PADEIRO
  						  WHEN raw LIKE '%PADEIR%'  THEN '848305' -- (CBO) PADEIRO
						  -- PASTOR
  						  WHEN raw LIKE '%PASTOR%'  THEN '263105' -- (CBO) MINISTRO DE CULTO RELIGIOSO
  						  WHEN raw LIKE '%SACERD%'  THEN '263105' -- (CBO) MINISTRO DE CULTO RELIGIOSO
						  -- PINTOR
  						  WHEN raw LIKE '%PINTOR%'  THEN '716610' -- (CBO) PINTOR DE OBRAS
						  -- PORTEIRO
  						  WHEN raw LIKE '%PORTEIR%' THEN '517410' -- (CBO) PORTEIRO DE EDIFICIOS
  						  WHEN raw LIKE '%ZELAD%'   THEN '517410' -- (CBO) PORTEIRO DE EDIFICIOS
  						  WHEN raw LIKE 'PORT ED%'  THEN '517410' -- (CBO) PORTEIRO DE EDIFICIOS
						  -- PROGRAMADOR
  						  WHEN raw LIKE '%PROGRAMAD%'  THEN '212405' -- (CBO) ANALISTA DE DESENVOLVIMENTO DE SISTEMAS
						  -- PROFESSOR
  						  WHEN raw LIKE '%PROFESSOR%' OR (raw LIKE '%PROF%' and raw LIKE '%ENSI%') THEN '234505' -- (CBO) PROFESSOR DE ENSINO SUPERIOR NA AREA DE DIDATICA
						  -- PROTETICO
  						  WHEN raw LIKE '%PROTETIC%'  THEN '322410' -- (CBO) PROTETICO DENTARIO
						  -- RECEPCIONISTA
  						  WHEN raw LIKE '%RECEP%'  THEN '422105' -- (CBO) RECEPCIONISTA, EM GERAL
						  -- SECRETARIAS
  						  WHEN raw LIKE '%SECRETAR%' THEN '252305' -- (CBO) SECRETARIA(O) EXECUTIVA(O)
						  -- SERVENTUARIOS DE JUSTICA
  						  WHEN raw LIKE '%SERVEN%' AND raw LIKE '%JUSTI%' THEN '351430' -- (CBO) AUXILIAR DE SERVICOS JURIDICOS
						  -- SERVIDOR PÚBLICO
  						  WHEN raw LIKE '%SERVID%' AND raw LIKE '%PUBLIC%' THEN '111415' -- (CBO) DIRIGENTE DO SERVICO PUBLICO MUNICIPAL
  						  WHEN raw LIKE '%MEMBR%'  AND raw LIKE '%PODER%'  THEN '111415' -- (CBO) DIRIGENTE DO SERVICO PUBLICO MUNICIPAL
						  -- VETERINARIOS  
  						  WHEN raw LIKE '%VETER%' THEN '223305' -- (CBO) MEDICO VETERINARIO
						  -- SEGUROS, CORRETORES DE SEGUROS e CORRETORES DE IMÓVEIS
						  WHEN raw LIKE '%CORRET%' AND raw LIKE '%SEGUR%'                                THEN '354505' -- (CBO) Corretor de Seguros
						  WHEN raw LIKE '%CORRET%' AND raw LIKE '%IMOV%'                                 THEN '354605' -- (CBO) Corretor de Imóveis
						  WHEN raw LIKE '%AUX%'    AND raw LIKE '%SEGURO%'                               THEN '411040' -- (CBO) Auxiliar de Seguros
						  WHEN raw LIKE '%ASSIS%'  AND raw LIKE '%COM%' AND raw LIKE '%SEGURO%'          THEN '351715' -- (CBO) Assistente comercial de seguros
						  WHEN raw LIKE '%ASSIS%'  AND raw LIKE '%TECN%' AND raw LIKE '%SEGURO%'         THEN '351720' -- (CBO) Assistente técnico de seguros
						  WHEN raw LIKE '%TECNIC%' AND raw LIKE '%SEGURO%'                               THEN '351740' -- (CBO) Técnico de seguros
						  WHEN raw LIKE '%AGENT%'  AND raw LIKE '%SEGURO%'                               THEN '351740' -- (CBO) Técnico de seguros
						  WHEN raw LIKE '%SECURITAR%'                                                    THEN '351705' -- (CBO) Securitário vai em Analista de seguros
						  WHEN raw LIKE '%CORRETOR%'                                                     THEN '354605' -- (CBO) Corretor de Imóveis
						  -- ADVOGADOS
						  WHEN raw LIKE '%ADVOGAD%' AND raw LIKE '%EXCET%'                               THEN '241005' -- (CBO) Advogado
						  WHEN raw LIKE '%ADVOGAD%' AND raw LIKE '%ESPECI%'                              THEN '241030' -- (CBO) Advogado (áreas especiais)
						  WHEN raw LIKE '%ADVOGAD%' AND raw LIKE '%CIVIL%'                               THEN '241015' -- (CBO) Advogado (direito civil)
						  WHEN raw LIKE '%ADVOGAD%' AND (raw LIKE '%PENA%' OR raw LIKE '%CRIMI%')        THEN '241025' -- (CBO) Advogado (direito penal)
						  WHEN raw LIKE '%ADVOGAD%' AND raw LIKE '%EMPRE%'                               THEN '241010' -- (CBO) Advogado de empresa
						  WHEN raw LIKE '%ADVOGAD%' AND raw LIKE '%UNIA%'                                THEN '241205' -- (CBO) Advogado da união
						  WHEN raw LIKE '%ADVOGAD%' AND raw LIKE '%PUBL%'                                THEN '241020' -- (CBO) Advogado (direito público)
						  WHEN raw LIKE '%ADVOGAD%' AND raw LIKE '%TRAB%'                                THEN '241035' -- (CBO) Advogado (direito do trabalho)
						  WHEN raw LIKE '%ADVOGAD%'							  	                         THEN '241005' -- (CBO) Advogado
						  -- ADMINISTRADORES
						  WHEN raw = 'ADMINISTRADOR'                                                     THEN '252105' -- (CBO) Administrador
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%EMPR%'                                    THEN '252105' -- (CBO) Administrador
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%AGENT%'                                   THEN '252105' -- (CBO) Administrador
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%SUPERV%'                                  THEN '410105' -- (CBO) Supervisor adminstrativo
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%GEREN%'                                   THEN '142105' -- (CBO) Gerente adminstrativo
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%FUND%'                                    THEN '252505' -- (CBO) Administrador de fundos e carteiras de investimento
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%PROFES%'                                  THEN '234810' -- (CBO) Professor de Administração
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%SIST%'                                    THEN '212315' -- (CBO) Administrador de sistemas operacionais
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%REDE%'                                    THEN '212310' -- (CBO) Administrador de redes
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%SEGURAN%'                                 THEN '212320' -- (CBO) Administrador em segurança da informação
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%BANC%' AND raw LIKE '%DADO%'              THEN '212305' -- (CBO) Administrador de banco de dados
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%RECUR%' AND raw LIKE '%HUM%'              THEN '142205' -- (CBO) Gerente de recursos humanos
						  WHEN raw LIKE '%ADM%' AND (raw LIKE '%TECNI%' OR raw LIKE '%TECNOLOGO%')       THEN '351305' -- (CBO) Técnico em administração
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%ASSIST%'                                  THEN '411010' -- (CBO) Assistente administrativo
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%ANALIS%'                                  THEN '411010' -- (CBO) Assistente administrativo
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%AUX%'                                     THEN '411010' -- (CBO) Assistente administrativo
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%EDIFIC%'                                  THEN '510110' -- (CBO) Administrador de edifícios
						  -- DIRETORES
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%DIRET%' AND raw not LIKE '%FINA%'         THEN '123105' -- (CBO) Diretor Administrativo
						  WHEN raw LIKE '%ADM%' AND raw LIKE '%DIRET%' AND raw LIKE '%FINA%'             THEN '123110' -- (CBO) Diretor Administrativo e Financeiro
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%EMPRES%'                                THEN '121010' -- (CBO) Diretor geral de empresa e organizações (exceto de interesse público)
						  WHEN raw LIKE '%DIRET%' AND (raw LIKE '%COMERC%' OR raw LIKE '%VENDA%')        THEN '123305' -- (CBO) Diretor comercial
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%FINANC%'                                THEN '123115' -- (CBO) Diretor financeiro
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%EDUC%' AND raw LIKE '%PUBL%'            THEN '131310' -- (CBO) Diretor de instituição educacional pública
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%EDUC%'                                  THEN '131305' -- (CBO) Diretor de instituição educacional da área privada
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%MARKET%'                                THEN '123310' -- (CBO) Diretor de marketing
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%INFORMA%'                               THEN '123605' -- (CBO) Diretor de tecnologia da informação
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%TECNOLOGI%'                             THEN '123605' -- (CBO) Diretor de tecnologia da informação
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%SAUD%'                                  THEN '131205' -- (CBO) Diretor de serviços de saúde
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%FOTOGR%'                                THEN '372105' -- (CBO) Diretor de fotografia
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%MIDIA%' AND raw LIKE '%PUBL%'           THEN '253120' -- (CBO) Diretor de mídia (publicidade)
						  WHEN raw LIKE '%DIRET%' AND raw LIKE '%MIDIA%' AND raw LIKE '%ART%'            THEN '252125' -- (CBO) Diretor de arte (publicidade)
						  WHEN raw LIKE '%DIRET%'                                                        THEN '121010' -- (CBO) Diretor geral de empresa e organizações (exceto de interesse público)
						  -- GERENTES
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%COMERC%'                               THEN '142305' -- (CBO) Gerente comercial
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%ADMINI%'                               THEN '142105' -- (CBO) Gerente administrativo
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%VEND%'                                 THEN '142320' -- (CBO) Gerente de vendas
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%COMPR%'                                THEN '142405' -- (CBO) Gerente de compras
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%PRODUC%'                               THEN '141205' -- (CBO) Gerente de produção e operações
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%PRODUT%'                               THEN '141705' -- (CBO) Gerente de produtos bancários
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%PROJ%' AND raw LIKE '%TECN%'           THEN '142520' -- (CBO) Gerente de projetos de tecnologia da informação
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%PROJ%' AND raw LIKE '%SERVI%'          THEN '142705' -- (CBO) Gerente de projetos e serviços de manutenção
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%SUPORT%'                               THEN '142530' -- (CBO) Gerente de suporte técnico de tecnologia da informação
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%DESENV%'                               THEN '142510' -- (CBO) Gerente de desenvolvimento de sistemas
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%FINANC%'                               THEN '142115' -- (CBO) Gerente financeiro
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%MARKET%'                               THEN '142315' -- (CBO) Gerente de marketing
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%AGENCIA%'                              THEN '141710' -- (CBO) Gerente de agência
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%CAPTA%'                                THEN '253205' -- (CBO) Gerente de captação (fundos e investimentos institucionais)
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%CONTA%'                                THEN '253220' -- (CBO) Gerente de contas - pessoa física e jurídica
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%LOGIST%'                               THEN '141615' -- (CBO) Gerente de logística (armazenagem e distribuição)
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%RESTAURANT%'                           THEN '141510' -- (CBO) Gerente de restaurante
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%BAR%'                                  THEN '141515' -- (CBO) Gerente de bar
						  WHEN raw LIKE '%GERENT%' AND raw LIKE '%HOTEL%'                                THEN '141505' -- (CBO) Gerente de hotel
						  WHEN raw LIKE '%GERENT%' AND (raw LIKE '%LOJA%' OR raw LIKE '%MERCAD%')        THEN '141415' -- (CBO) Gerente de loja
						  WHEN raw LIKE '%GERENT%' AND (raw LIKE '%HUMAN%' OR raw LIKE '%DEPART%')       THEN '142205' -- (CBO) Gerente de recursos humanos 
						  WHEN raw LIKE '%GERENT%'                                                       THEN '142105' -- (CBO) joga todo o restante no Ger. Adm.
						  -- COMERCIANTES
						  WHEN raw LIKE '%COMERCIAN%' AND raw LIKE '%VAREJ%'                             THEN '141410' -- (CBO) Comerciante varejista
						  WHEN raw LIKE '%COMERCIAN%' AND raw LIKE '%ATACAD%'                            THEN '141405' -- (CBO) Comerciante atacadista
						  WHEN raw LIKE '%COMERCIAN%'                                                    THEN '141410' -- (CBO) Comerciante varejista
						  -- VENDEDORES
						  WHEN raw LIKE '%VENDED%' AND raw LIKE '%VAREJ%'                                THEN '521110' -- (CBO) Vendedor de comércio varejista
						  WHEN raw LIKE '%VENDED%' AND raw LIKE '%ATACAD%'                               THEN '521105' -- (CBO) Vendedor de comércio atacadista
						  WHEN raw LIKE '%VENDED%' AND raw LIKE '%DOMICI%'                               THEN '524105' -- (CBO) Vendedor em domicílio
						  WHEN raw LIKE '%VENDED%' AND raw LIKE '%PRACIS%'                               THEN '354145' -- (CBO) Vendedor pracista
						  WHEN raw LIKE '%VEND%'   AND raw LIKE '%PRAC%'                                 THEN '354145' -- (CBO) Vendedor pracista
						  WHEN raw LIKE '%VENDED%' AND raw LIKE '%PERMI%'                                THEN '524215' -- (CBO) Vendedor permissionário
						  WHEN raw LIKE '%VENDED%' AND raw LIKE '%AMBUL%'                                THEN '524305' -- (CBO) Vendedor ambulante
						  WHEN raw LIKE '%VENDED%'                                                       THEN '521110' -- (CBO) Vendedor de comércio varejista
						  -- CONTADORES
						  WHEN raw LIKE '%CONTADOR%' AND raw LIKE '%AUDITOR%'                            THEN '252205' -- (CBO) Auditor (contadores e afins)
						  WHEN raw LIKE '%CONTADOR%'                                                     THEN '252210' -- (CBO) Contador
						  -- PROPRIETÁRIO DE ESTABELECIMENTO  (reclassificador como 'diretor de empresa' na falta de uma melhor reclassificação...														  
						  WHEN raw LIKE '%PROPRIET%' AND raw LIKE '%ESTAB%'                              THEN '121010' -- (CBO) Diretor geral de empresa e organizações (exceto de interesse público)
						  WHEN raw LIKE '%PROPR%' AND raw LIKE '%ESTAB%'                                 THEN '121010' -- (CBO) Diretor geral de empresa e organizações (exceto de interesse público)
						  WHEN raw LIKE '%PROPRIET%'                                                     THEN '121010' -- (CBO) Diretor geral de empresa e organizações (exceto de interesse público)
						  -- REPRESENTANTE COMERCIAL AUTONOMO
						  WHEN raw LIKE '%REPRES%' AND raw LIKE '%COMERC%' AND raw LIKE '%AUTON%'        THEN '354705' -- (CBO) Representante comercial autônomo
						  WHEN raw LIKE '%REPRES%' AND raw LIKE '%COMERC%'                               THEN '354705' -- (CBO) Representante comercial autônomo
						  WHEN raw LIKE '%REPRES%'                                                       THEN '354705' -- (CBO) Representante comercial autônomo
						  -- AUXILIAR DE ESCRITÓRIO, ESCRITURÁRIOS e ESCRITORES
						  WHEN raw LIKE '%AUX%' AND raw LIKE '%ESCRIT%'                                  THEN '411005' -- (CBO) Auxiliar de escritório
						  WHEN raw LIKE '%ESCRITORIO%' AND raw LIKE '%REPARA%'                           THEN '954305' -- (CBO) Reparador de equipamentos de escritório
						  WHEN raw LIKE '%ESCRITORIO%'                                                   THEN '411005' -- (CBO) Auxiliar de escritório
						  WHEN raw LIKE '%ESCRITUR%' AND raw LIKE '%ESTATIS%'                            THEN '424125' -- (CBO) Escriturário de estatística
						  WHEN raw LIKE '%ESCRITUR%' AND raw LIKE '%BANC%'                               THEN '413225' -- (CBO) Escriturário de banco
						  WHEN raw LIKE '%ESCRITURARI%'                                                  THEN '413225' -- (CBO) Escriturário de banco
						  WHEN raw LIKE '%ESCRITOR%' AND raw LIKE '%FIC%' AND raw LIKE '%NAO%'           THEN '261520' -- (CBO) Escritor de não ficção
						  WHEN raw LIKE '%ESCRITOR%' AND raw LIKE '%FIC%'                                THEN '261515' -- (CBO) Escritor de ficção
						  WHEN raw LIKE '%ESCRITOR%'                                                     THEN '261520' -- (CBO) Escritor de não ficção
						  WHEN raw LIKE '%TRADUTOR%'                                                     THEN '261420' -- (CBO) Tradutor
						  -- ENGENHEIROS
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%CIV%'                                     THEN '214205' -- (CBO) Engenheiro civil
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%MECAN%'                                   THEN '214405' -- (CBO) Engenheiro mecânico
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%MECAT%'                                   THEN '202105' -- (CBO) Engenheiro mecatrônico
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%METALU%'                                  THEN '214610' -- (CBO) Engenheiro metalurgista
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%AUTOMA%'                                  THEN '202110' -- (CBO) Engenheiro de controle de automação
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%QUALID%'                                  THEN '214910' -- (CBO) Engenheiro de controle de qualidade
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%FLOR%'                                    THEN '222120' -- (CBO) Engenheiro florestal
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%QUIM%'                                    THEN '214505' -- (CBO) Engenheiro químico
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%AMBI%'                                    THEN '214005' -- (CBO) Engenheiro ambiental
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%PROD%'                                    THEN '214905' -- (CBO) Engenheiro de produção
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%ELETRI%'                                  THEN '214305' -- (CBO) Engenheiro eletricista
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%ELETRO%'                                  THEN '214310' -- (CBO) Engenheiro eletrônico
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%EQUIP%'                                   THEN '212210' -- (CBO) Engenheiro de equipamentos em computação
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%APLIC%'                                   THEN '212205' -- (CBO) Engenheiro de aplicativos em computação
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%SISTEM%'                                  THEN '212215' -- (CBO) Engenheiros de sistemas operacionais em computação
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%SEGUR%'                                   THEN '214915' -- (CBO) Engenheiro de segurança do trabalho
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%PROFES%'                                  THEN '234310' -- (CBO) Professor de engenharia
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%ALIM%'                                    THEN '222205' -- (CBO) Engenheiro de alimentos
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%AGRON%'                                   THEN '222110' -- (CBO) Engenheiro agrônomo
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%AGRIM%'                                   THEN '214805' -- (CBO) Engenheiro agrimensor
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%AGRIC%'                                   THEN '222105' -- (CBO) Engenheiro agrícola
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%MINA%'                                    THEN '214705' -- (CBO) Engenheiro de minas
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%MATER%'                                   THEN '214605' -- (CBO) Engenheiro de materiais
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%TELE%'                                    THEN '214340' -- (CBO) Engenheiro de telecomunicações
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%BIO%'                                     THEN '201105' -- (CBO) Bioengenheiro
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%TECN%' AND raw LIKE '%APOI%'              THEN '301205' -- (CBO) Técnico de apoio à bioengenharia
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%LOGIST%'                                  THEN '214945' -- (CBO) Engenheiro de logística
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%PESCA%'                                   THEN '222115' -- (CBO) Engenheiro de pesca
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%AERON%'                                   THEN '214425' -- (CBO) Engenheiro aeronáutico
						  WHEN raw LIKE '%ENG%' AND raw LIKE '%NAVAL%'                                   THEN '214430' -- (CBO) Engenheiro naval
						  WHEN raw LIKE '%ENG%'                                                          THEN '214205' -- (CBO) todos os demais em Engenheiro civil
						  ELSE NULL
					 END 
			   WHERE cbo_manual IS NULL
					 ;
/*
   Filtro 4: Código CBO imputado diretamente mas com hífen
*/
UPDATE aggregator.pred_vida_proddb_occupations
	SET cbo_manual = replace(raw, '-', '')
		WHERE cbo_manual IS NULL
AND LENGTH(raw) = 7
AND POSITION('-' IN RIGHT(raw, 3)) = 1; /* No script original, usamos LEFT(RIGHT(raw,3),1) = '-'. Em PostgreSQL uma maneira mais clara e compatível é usar a função POSITION.
Verifica se o hífen - está na primeira posição dos últimos três caracteres da string raw. RIGHT(raw, 3) obtém os últimos três caracteres da string raw.*/

/*
   Filtro 5: Regras de Aceitação (LUMA, Agosto 2020)

	PostgreSQL não suporta a sintaxe UPDATE ... LEFT JOIN da mesma forma que MySQL. Em PostgreSQL, 
	a atualização com junções deve ser feita utilizando a cláusula FROM para incluir a tabela a ser juntada e definir a junção na cláusula WHERE. 
	PostgreSQL efetivamente faz a junção interna durante a atualização, mas a maneira como se especifica a junção é diferente.

	https://www.postgresqltutorial.com/postgresql-tutorial/postgresql-update-join/
*/

UPDATE aggregator.pred_vida_proddb_occupations AS occp
SET cbo_luma_udw = CASE
                        WHEN occp.cbo_manual IN ('APOSENTADO', 'DOMESTICA', 'ESTUDANTE') THEN 'SIM'
                        ELSE luma.subscricao
                   END
FROM public_dbs.cbo_luma_agosto_2020 AS luma 
WHERE occp.cbo_manual IS NOT NULL
AND occp.cbo_manual = luma.codigo;

/*
   Filtro 6: Grande Grupo (CBO 2002)

	PostgreSQL não suporta a sintaxe UPDATE ... LEFT JOIN da mesma forma que MySQL. Em PostgreSQL, 
	a atualização com junções deve ser feita utilizando a cláusula FROM para incluir a tabela a ser juntada e definir a junção na cláusula WHERE. 
	PostgreSQL efetivamente faz a junção interna durante a atualização, mas a maneira como se especifica a junção é diferente.

	https://www.postgresqltutorial.com/postgresql-tutorial/postgresql-update-join/
*/

UPDATE aggregator.pred_vida_proddb_occupations AS occp
SET cbo_gdegrp = CASE
                    WHEN cbo.grande_grupo IS NULL THEN occp.cbo_manual
                    ELSE cbo.grande_grupo
                 END
FROM public_dbs.cbo_ocupacao AS cbo 
WHERE occp.cbo_manual = cbo.codigo;

/*
   Apaga a tabela temporária para imputação de CBO com base nos dados truncados
*/

DROP TABLE IF EXISTS aggregator.pred_vida_proddb_occupations_reclass;

/*
	------------------------------------------------
	Tabela permanente 'pred_vida_proddb_cities'
	------------------------------------------------
	Tabela permanente para embasar reclassificação
	do ~codMunicipioIBGE~ original
*/
-- aux.city

/*##########################################################################################################################################################*/

DROP TABLE IF EXISTS aggregator.aux_city;

CREATE TABLE aggregator.aux_city AS
SELECT DISTINCT
d.company_id,
d.applicant_id,
    CAST(REPLACE(meta_value::text, '"', '') AS VARCHAR) AS raw
FROM 
aggregator.data_inputs AS d
INNER JOIN
aggregator.pred_vida_ids AS ids
ON 
	d.company_id = ids.company_id
AND 
	d.applicant_id = ids.applicant_id
WHERE 
	meta_key = 'city';

CREATE INDEX idx_city
ON aggregator.aux_city (company_id, applicant_id);

-- aux.state

DROP TABLE IF EXISTS aggregator.aux_state;

CREATE TABLE aggregator.aux_state AS
SELECT DISTINCT 
    d.company_id, 
    d.applicant_id, 
    CAST(REPLACE(meta_value::text, '"', '') AS VARCHAR) AS raw
FROM 
    aggregator.data_inputs AS d
INNER JOIN 
    aggregator.pred_vida_ids AS ids
ON 
    d.company_id = ids.company_id
    AND d.applicant_id = ids.applicant_id
WHERE 
    meta_key = 'state';
    
CREATE INDEX idx_state
ON aggregator.aux_state (company_id, applicant_id);

-- aux_citystate

DROP TABLE IF EXISTS aggregator.aux_citystate;

CREATE TABLE aggregator.aux_citystate AS
SELECT -- ************************************************************************************************ TIRAR DUVIDA COM RAFA, NÃO SERIA SELECT DISTINCT? 
    ids.company_id,
    ids.applicant_id,
    c.raw AS city,
    s.raw AS state
FROM 
    aggregator.pred_vida_ids AS ids
LEFT JOIN 
    aggregator.aux_city AS c 
ON 
    ids.company_id = c.company_id 
    AND ids.applicant_id = c.applicant_id
LEFT JOIN 
    aggregator.aux_state AS s 
ON 
    ids.company_id = s.company_id 
    AND ids.applicant_id = s.applicant_id;

CREATE INDEX idx_citystate
ON aggregator.aux_citystate (left(city, 140), left(state, 2));

-- Atualizar a cidade e o estado para maiúsculas e remover espaços em branco extras
UPDATE aggregator.aux_citystate 
SET 
    city = TRIM(UPPER(TRANSLATE(city, 'ÃÁÂÀÊÉÈÍÇÔÓÒÕÚÜ', 'AAAEEIÇOOOOOUU'))), -- A função TRANSLATE proporciona uma maneira mais compacta e eficiente do que o REPLACE.
    state = TRIM(UPPER(TRANSLATE(state, 'ÃÁÂÀÊÉÈÍÇÔÓÒÕÚÜ', 'AAAEEIÇOOOOOUU'))); -- A função TRANSLATE proporciona uma maneira mais compacta e eficiente do que o REPLACE.

-- Mapeamento de estado para suas siglas
UPDATE aggregator.aux_citystate 
SET 
    state = CASE 
        		WHEN state = 'RONDONIA' THEN 'RO'
        		WHEN state = 'ACRE' THEN 'AC'
        		WHEN state = 'AMAZONAS' THEN 'AM'
        		WHEN state = 'RORAIMA' THEN 'RR'
        		WHEN state = 'PARA' THEN 'PA'
        		WHEN state = 'AMAPA' THEN 'AP'
        		WHEN state = 'TOCANTINS' THEN 'TO'
        		WHEN state = 'MARANHAO' THEN 'MA'
        		WHEN state = 'PIAUI' THEN 'PI'
        		WHEN state = 'CEARA' THEN 'CE'
        		WHEN state = 'RIO GRANDE DO NORTE' THEN 'RN'
        		WHEN state = 'PARAIBA' THEN 'PB'
        		WHEN state = 'PERNAMBUCO' THEN 'PE'
        		WHEN state = 'ALAGOAS' THEN 'AL'
        		WHEN state = 'SERGIPE' THEN 'SE'
        		WHEN state = 'BAHIA' THEN 'BA'
        		WHEN state = 'MINAS GERAIS' THEN 'MG'
        		WHEN state = 'ESPIRITO SANTO' THEN 'ES'
        		WHEN state = 'RIO DE JANEIRO' THEN 'RJ'
        		WHEN state = 'SAO PAULO' THEN 'SP'
        		WHEN state = 'PARANA' THEN 'PR'
        		WHEN state = 'SANTA CATARINA' THEN 'SC'
        		WHEN state = 'RIO GRANDE DO SUL' THEN 'RS'
        		WHEN state = 'MATO GROSSO DO SUL' THEN 'MS'
        		WHEN state = 'MATO GROSSO' THEN 'MT'
        		WHEN state = 'GOIAS' THEN 'GO'
        		WHEN state = 'DISTRITO FEDERAL' THEN 'DF'
        		ELSE LEFT(state, 2) -- A função LEFT(state, 2) pega os dois primeiros caracteres da string state.
END;

-- Traz codMunicipioIBGE da public_dbs.ibge_municipios
DROP TABLE IF EXISTS aggregator.pred_vida_proddb_cities;

CREATE TABLE aggregator.pred_vida_proddb_cities AS
SELECT 
    cs.company_id,
    cs.applicant_id,
    cs.city,
    cs.state,
    ib.codigo AS codMunicipioIBGE
FROM 
    aggregator.aux_citystate AS cs
LEFT JOIN 
    public_dbs.ibge_municipios AS ib
ON 
    cs.city = ib.municipio AND cs.state = ib.uf;

CREATE INDEX idx_cities
ON aggregator.pred_vida_proddb_cities (company_id, applicant_id);

-- remove tabelas temporárias auxiliares
DROP TABLE IF EXISTS aggregator.aux_city;
DROP TABLE IF EXISTS aggregator.aux_state; 
DROP TABLE IF EXISTS aggregator.aux_citystate; 

/* 
  Tabela temporária: pred_vida_proddb_long  
*/
DROP TABLE IF EXISTS aggregator.pred_vida_proddb_long;

CREATE TABLE aggregator.pred_vida_proddb_long AS
SELECT di.company_id,
       di.applicant_id,
       di.meta_key,
       REPLACE(di.meta_value::text, '"', '') AS meta_value -- meta.value ajustado para text antes do REPLACE
FROM aggregator.data_inputs AS di
INNER JOIN aggregator.pred_vida_ids AS ids
ON ids.company_id = di.company_id
AND ids.applicant_id = di.applicant_id
WHERE di.meta_key NOT LIKE '%bigboost.%'
AND di.meta_key NOT LIKE '%_acidente%'
AND di.meta_key NOT LIKE '%_accident%'
AND di.meta_key NOT LIKE '%codproposal%'
AND di.meta_key NOT LIKE '%company_category%'
AND di.meta_key NOT LIKE '%dental_expenses%'
AND di.meta_key NOT LIKE '%_opinion%'
AND di.meta_key NOT LIKE '%profissao%'
AND di.meta_key NOT LIKE '%risco_ocupacional%'
AND di.meta_key NOT LIKE '%zip%'        -- LGPD...
AND di.meta_key NOT LIKE 'name'         -- LGPD...
AND di.meta_key NOT LIKE '%cpf%'        -- LGPD...
AND di.meta_key NOT LIKE '%occupation%'; -- Profissão (já tratada no topo deste batch script)

/* índice para agilizar todas as queries daqui em diante */
CREATE INDEX idx_proddb_long
ON aggregator.pred_vida_proddb_long(company_id, applicant_id, meta_key);        

DO $$
DECLARE
    create_view_statement TEXT;
BEGIN
    -- Definir o limite de tamanho máximo da concatenação de strings (não é suportado no PostgreSQL)
    -- Não é necessário no PostgreSQL, pois não há parâmetro `concat_max_length`
    
    -- Dropar a VIEW se ela já existir
    EXECUTE 'DROP VIEW IF EXISTS aggregator.vw_vida_proddb_wide';
    
    -- Definir a instrução para criar a VIEW
    -- Ajuste para criar a VIEW com comentários e variável statement
    SELECT 
        CONCAT(
            'CREATE OR REPLACE VIEW aggregator.vw_vida_proddb_wide AS (',
            'SELECT company_id AS __company_id, applicant_id AS __applicant_id, ', statement, 
            ' FROM aggregator.pred_vida_proddb_long GROUP BY 1, 2)'
        )
    INTO create_view_statement
    FROM 
        (
            SELECT 
                STRING_AGG(statement, ', ') AS statement
            FROM 
                (
                    SELECT 
                        CONCAT('MAX(CASE WHEN meta_key = ''', meta_key, ''' THEN meta_value END) AS ', meta_key) AS statement
                    FROM 
                        (
                            SELECT DISTINCT meta_key FROM aggregator.pred_vida_proddb_long
                        ) AS distinct_meta_keys
                ) AS grouped_fields
        ) AS final_statement_table;

    -- Executar a declaração para criar a VIEW
    EXECUTE create_view_statement;

    -- Dropar a tabela temporária pred_vida_proddb_wide, se ela existir
    EXECUTE 'DROP TABLE IF EXISTS aggregator.pred_vida_proddb_wide';

    -- Criar a tabela temporária pred_vida_proddb_wide
    EXECUTE '
        CREATE TABLE aggregator.pred_vida_proddb_wide AS
        SELECT *
        FROM aggregator.vw_vida_proddb_wide
    ';

    -- Corrigir o campo salary na tabela temporária pred_vida_proddb_wide
    EXECUTE '
        UPDATE aggregator.pred_vida_proddb_wide
        SET salary = REPLACE(
                        REPLACE(
                            CASE
                                WHEN SUBSTRING(salary FROM LENGTH(salary)-2 FOR 1) IN (''.'', '''') THEN LEFT(salary, LENGTH(salary)-3)
                                ELSE salary
                            END,
                            ''.'', ''''
                        ),
                        '''', ''''
                    )
    ';

END $$;

/* TRATAMENTO DOS DADOS DAS COLUNAS PESO E ALTURA DA TABELA PRED_VIDA_PRODDB_WIDE (RETIRADA DE VÍRGULAS, LETRAS E PALAVRAS) */ 

UPDATE aggregator.pred_vida_proddb_wide
SET peso = CASE 
    WHEN TRIM(peso) ~ '^\d+,\d+$' THEN REPLACE(TRIM(peso), ',', '.')  -- Substituir vírgula por ponto
    WHEN TRIM(peso) ~ '^\d+\.?\d*( kg|)$' THEN REGEXP_REPLACE(TRIM(peso), '[^0-9.]', '', 'g')  -- Remover palavras
    WHEN TRIM(peso) ~ '^\d+\.?\d*$' THEN TRIM(peso)                  -- Manter números com ponto ou inteiros
    ELSE NULL                                            -- Substituir frases por NULL
END;
UPDATE aggregator.pred_vida_proddb_wide
SET altura = CASE 
    WHEN TRIM(altura) ~ '^\d+,\d+$' THEN REPLACE(TRIM(altura), ',', '.')  -- Substituir vírgula por ponto
    WHEN TRIM(altura) ~ '^\d+\.?\d*( cm|)$' THEN REGEXP_REPLACE(TRIM(altura), '[^0-9.]', '', 'g')  -- Remover palavras
    WHEN TRIM(altura) ~ '^\d+\.?\d*$' THEN TRIM(altura)                   -- Manter números com ponto ou inteiros
    ELSE NULL                                                 -- Substituir frases por NULL
END;
UPDATE aggregator.pred_vida_proddb_wide
SET imc = CASE 
    WHEN TRIM(imc) ~ '^\d+,\d+$' THEN REPLACE(TRIM(imc), ',', '.')  -- Substituir vírgula por ponto
    WHEN TRIM(imc) ~ '^\d+\.?\d*$' THEN TRIM(imc)  -- Manter números com ponto ou inteiros
    ELSE NULL
END;

-- Índice para agilizar todas as queries daqui em diante
CREATE INDEX idx_proddb_wide
ON aggregator.pred_vida_proddb_wide(__company_id, __applicant_id);

/* 
   Exclui tabela e view temporárias e necessárias para a base
   de produção no formato desempilhado
*/
DROP VIEW IF EXISTS aggregator.vw_vida_proddb_wide;
DROP TABLE IF EXISTS aggregator.pred_vida_proddb_long;
DROP TABLE IF EXISTS aggregator.pred_vida_ids;

-- Tabela persistente: pred_vida_wide_data (usada no modelo GNU R)
-- Desempilhada, contendo união dos tratamentos de proddb e bboost
-- Ainda carece do join com os datasets públicos
-- Cuja chave primária será 'codMunicipioIBGE'

DROP TABLE IF EXISTS aggregator.pred_vida_wide_data;

CREATE TABLE aggregator.pred_vida_wide_data AS
SELECT
    -- Identificação do proponente
    p.__company_id      AS company_id,
    p.__applicant_id    AS applicant_id,
    CASE
        -- interview_date e finished_date ambas nulas
        WHEN (p.interview_date IS NULL OR p.interview_date = '0000-00-00') AND
             (p.finished_date IS NULL OR p.finished_date = '0000-00-00') THEN NULL
        -- interview_date nula e finished_date não nula
        WHEN (p.interview_date IS NULL OR p.interview_date = '0000-00-00') AND
             (p.finished_date IS NOT NULL AND p.finished_date != '0000-00-00') THEN p.finished_date
        -- interview_date não nula
        ELSE p.interview_date
    END AS data_entrevista
	,cit.city    AS cidade
	,cit.state   AS UF
	,p.birthday  AS data_nascimento 

,CASE
    -- birthday nula
    WHEN (p.birthday IS NULL OR p.birthday = '0000-00-00') THEN NULL

    -- interview_date E finished_date ambas nulas
    WHEN (p.interview_date IS NULL OR p.interview_date = '0000-00-00') AND
         (p.finished_date IS NULL OR p.finished_date = '0000-00-00') THEN NULL

    -- interview_date nula MAS finished_date e birthday não nulas
    WHEN (p.interview_date IS NULL OR p.interview_date = '0000-00-00') AND
         (p.finished_date IS NOT NULL AND p.finished_date != '0000-00-00') AND
         (p.birthday IS NOT NULL AND p.birthday != '0000-00-00') THEN
        EXTRACT(YEAR FROM AGE(TO_DATE(p.finished_date, 'YYYY-MM-DD'), TO_DATE(p.birthday, 'YYYY-MM-DD')))

    -- finished_date nula MAS interview_date e birthday não nulas
    WHEN (p.interview_date IS NOT NULL AND p.interview_date != '0000-00-00') AND
         (p.finished_date IS NULL OR p.finished_date = '0000-00-00') AND
         (p.birthday IS NOT NULL AND p.birthday != '0000-00-00') THEN
        EXTRACT(YEAR FROM AGE(TO_DATE(p.interview_date, 'YYYY-MM-DD'), TO_DATE(p.birthday, 'YYYY-MM-DD')))

    -- finished_date, interview_date e birthday não nulas
    WHEN (p.interview_date IS NOT NULL AND p.interview_date != '0000-00-00') AND
         (p.finished_date IS NOT NULL AND p.finished_date != '0000-00-00') AND
         (p.birthday IS NOT NULL AND p.birthday != '0000-00-00') THEN
        EXTRACT(YEAR FROM AGE(TO_DATE(p.interview_date, 'YYYY-MM-DD'), TO_DATE(p.birthday, 'YYYY-MM-DD')))
END AS idade_na_data_entrevista,


CASE 
WHEN p.sex = '2' THEN '2' ELSE '1' END AS sexo, -- Em Postgres é utilizado CASE WHEN no lugar de IF.
-- Cobertura de Morte Natural
p.capital_value as cob_morte_capital_segurado_original,
replace(
    replace(
        CASE
            WHEN LEFT( RIGHT(p.capital_value, 3), 1) IN ('.',',')
                 THEN LEFT( p.capital_value, LENGTH(p.capital_value)-3)
            ELSE  p.capital_value
        END, '.','')
    ,',','')::numeric AS cob_morte_capital_segurado,
CASE 
        WHEN CAST(p.capital_status AS INTEGER) = 1 THEN 0 
        ELSE 1 
    END AS cob_morte_target,
    CASE 
        WHEN CAST(p.capital_status AS INTEGER) = 1 THEN 'aceito' 
        WHEN CAST(p.capital_status AS INTEGER) = 2 THEN 'recusado' 
        WHEN CAST(p.capital_status AS INTEGER) = 5 THEN 'agravado' 
        ELSE NULL
    END AS cob_morte_decisao,

-- Fatores de risco
CASE WHEN p.sedentarismo = '2' THEN '2' ELSE '1' END AS fator_risco_sedentarismo,
CASE WHEN p.alcool = '2' THEN '2' ELSE '1' END AS fator_risco_alcoolismo,
CASE WHEN p.drogas = '2' THEN '2' ELSE '1' END AS fator_risco_drogas,
CASE WHEN p.fumante = '2' THEN '2' ELSE '1' END AS fator_risco_fumante,
CASE WHEN p.tabagismo = '2' THEN '2' ELSE '1' END AS fator_risco_tabagismo,
CASE WHEN p.hipertensao = '2' THEN '2' ELSE '1' END AS fator_risco_hipertensao,
CASE WHEN p.hipertensao_arterial = '2' THEN '2' ELSE '1' END AS fator_risco_hipertensao_arterial,
CASE WHEN p.esporte_risco = '2' THEN '2' ELSE '1' END AS fator_risco_esporte_risco

-- Índice de Massa Corpórea recalculada pela área de Ciência de Dados
,CASE
    -- altura e peso iguais a zero mas IMC original válido...
    WHEN (COALESCE(p.altura::DECIMAL, 0.0) + COALESCE(p.peso::DECIMAL, 0.0) = 0.0) 
        AND (CAST(p.imc AS DECIMAL(12,2)) BETWEEN 5 AND 200)
        THEN CAST(p.imc AS DECIMAL(12,2))
    -- se altura e/ou peso forem nulos, zerados ou não numéricos...
    WHEN COALESCE(NULLIF(p.altura::TEXT, '')::DECIMAL, 0.0) = 0.0
        OR COALESCE(NULLIF(p.peso::TEXT, '')::DECIMAL, 0.0) = 0.0
        THEN NULL
    -- se altura > 3 e peso < 3 ...
    WHEN COALESCE(NULLIF(p.altura::DECIMAL, 0.0), 0.0) > 3.0
        AND COALESCE(NULLIF(p.peso::DECIMAL, 0.0), 0.0) < 3.0
        THEN ROUND(p.altura::DECIMAL / POWER(p.peso::DECIMAL, 2), 2)
    -- se altura > 3 e peso > 3 ...
    WHEN COALESCE(NULLIF(p.altura::DECIMAL, 0.0), 0.0) > 3.0
        AND COALESCE(NULLIF(p.peso::DECIMAL, 0.0), 0.0) > 3.0
        THEN ROUND(p.peso::DECIMAL / POWER(p.altura::DECIMAL / 100.0, 2), 2)
    -- se 1 < altura < 3 e peso < 300 ...
    WHEN COALESCE(NULLIF(p.altura::DECIMAL, 0.0), 0.0) BETWEEN 1.0 AND 3.0
        AND COALESCE(NULLIF(p.peso::DECIMAL, 0.0), 0.0) < 300.0
        THEN ROUND(p.peso::DECIMAL / POWER(p.altura::DECIMAL, 2), 2)
        -- se altura < 1 e/ou peso > 300, dados foram digitados erroneamente, portanto retorne NULL
        ELSE NULL
    END AS indice_massa_corporea_recalculado,
    -- Risco Médico: Doenças Circulatórias ou Cardiovasculares
					 ,CASE
						 WHEN p.doenca_circulatoria_ou_cardiovascular = '2' THEN 'Yes'
						 WHEN p.circ_cardio_angina_infarto_aneurisma = '2'  THEN 'Yes'
						 WHEN p.circ_cardio_arritmia = '2'                  THEN 'Yes'
						 WHEN p.circ_cardio_avc = '2'                       THEN 'Yes'
						 WHEN p.circ_cardio_embolia_trombose = '2'          THEN 'Yes'
						 WHEN p.circ_cardio_insuficiencia_cardiaca = '2'    THEN 'Yes'
						 ELSE 'No'
					 END AS med_circulatory_or_cardiovascular_disease
					 ,CASE p.circ_cardio_angina_infarto_aneurisma WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_circ_cardio_angina_mi_aneurysm
					 ,CASE p.circ_cardio_arritmia                 WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_circ_cardio_arrhythmia
					 ,CASE p.circ_cardio_avc                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_circ_cardio_cva
					 ,CASE p.circ_cardio_embolia_trombose         WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_circ_cardio_embolism_thrombosis
					 ,CASE p.circ_cardio_insuficiencia_cardiaca   WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_circ_cardio_cardiac_insufficiency
					 -- Risco Médico: Doenças Respiratórias
					 ,CASE
						 WHEN p.doenca_respiratoria = '2'              THEN 'Yes'
						 WHEN p.respir_asma_ou_bronquite = '2'         THEN 'Yes'
						 WHEN p.respir_dpoc_ou_enfisema_pulmonar = '2' THEN 'Yes'
						 WHEN p.respir_tuberculose = '2'               THEN 'Yes'
						 ELSE 'No'
					 END AS med_respiratory_disease
					 ,CASE p.respir_asma_ou_bronquite         WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_respir_ashtma_or_bronchitis
					 ,CASE p.respir_dpoc_ou_enfisema_pulmonar WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_respir_copd_or_pulmonary_emphysema
					 ,CASE p.respir_tuberculose               WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_respir_tuberculosis
					 -- Risco Médico: Câncer
					 ,CASE
						 WHEN p.doenca_cancer = '2'              THEN 'Yes'
						 WHEN p.cancer_linfoma = '2'             THEN 'Yes'
						 WHEN p.cancer_linfoma_hodgkin = '2'     THEN 'Yes'
						 WHEN p.cancer_linfoma_nao_hodgkin = '2' THEN 'Yes'
						 WHEN p.cancer_leucemia = '2'            THEN 'Yes'
						 WHEN p.cancer_mama = '2'                THEN 'Yes'
						 WHEN p.cancer_ovario = '2'              THEN 'Yes'
						 WHEN p.cancer_pulmao = '2'              THEN 'Yes'
						 WHEN p.cancer_prostata = '2'            THEN 'Yes'
						 WHEN p.cancer_intestino = '2'           THEN 'Yes'
						 WHEN p.cancer_figado = '2'              THEN 'Yes'
						 WHEN p.cancer_pancreas = '2'            THEN 'Yes'
						 WHEN p.cancer_pele = '2'                THEN 'Yes'
						 ELSE 'No'
					 END AS med_cancer_disease
					 ,CASE p.cancer_linfoma             WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_lymphoma
					 ,CASE p.cancer_linfoma_hodgkin     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_lymphoma_hodgkin
					 ,CASE p.cancer_linfoma_nao_hodgkin WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_lymphoma_non_hodgkin
					 ,CASE p.cancer_leucemia            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_leukaemia
					 ,CASE p.cancer_mama                WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_breast
					 ,CASE p.cancer_ovario              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_ovary
					 ,CASE p.cancer_pulmao              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_lung
					 ,CASE p.cancer_prostata            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_prostate
					 ,CASE p.cancer_intestino           WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_intestine
					 ,CASE p.cancer_figado              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_liver
					 ,CASE p.cancer_pancreas            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_pancreas
					 ,CASE p.cancer_pele                WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_cancer_skin
					 -- Risco Médico: Doenças Endócrinas
					 ,CASE
						 WHEN p.doenca_endocrina = '2'                         THEN 'Yes'
						 WHEN p.endocr_intolerancia_glicose_pre_diabetes = '2' THEN 'Yes'
						 WHEN p.endocr_diabetes = '2'                          THEN 'Yes'
						 WHEN p.endocr_hiper_hipo_tireoidismo = '2'            THEN 'Yes'
						 WHEN p.endocr_tireoidite_hashimoto = '2'              THEN 'Yes'
						 ELSE 'No'
					 END AS med_endocrine_disease
					 ,CASE p.endocr_intolerancia_glicose_pre_diabetes WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_endocr_glycose_intolerance_pre_diabetes
					 ,CASE p.endocr_diabetes                          WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_endocr_diabetes
					 ,CASE p.endocr_hiper_hipo_tireoidismo            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_endocr_hiper_hypo_thyroidism
					 ,CASE p.endocr_tireoidite_hashimoto              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_endocr_thyroiditis_hashimoto
					 -- Risco Médico: Doenças Neurológicas
					 ,CASE
						 WHEN p.doenca_neurologica = '2'                  THEN 'Yes'
						 WHEN p.neuro_esclerose_multipla = '2'            THEN 'Yes'
						 WHEN p.neuro_esclerose_lateral_amiotrofica = '2' THEN 'Yes'
						 WHEN p.neuro_epilepsia_convulsao = '2'           THEN 'Yes'
						 WHEN p.neuro_parkinson = '2'                     THEN 'Yes'
						 WHEN p.neuro_alzheimer = '2'                     THEN 'Yes'
						 ELSE 'No'
					 END AS med_neurologic_disease
					 ,CASE p.neuro_esclerose_multipla            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_neuro_multiple_sclerosis
					 ,CASE p.neuro_esclerose_lateral_amiotrofica WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_neuro_amyotrophic_lateral_sclerosis
					 ,CASE p.neuro_epilepsia_convulsao           WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_neuro_epilepsy_convulsion
					 ,CASE p.neuro_parkinson                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_neuro_parkinson
					 ,CASE p.neuro_alzheimer                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_neuro_alzheimer
					 -- Risco Médico: Doenças Psiquiátricas
					 ,CASE
						 WHEN p.doenca_psiquiatrica = '2'    THEN 'Yes'
						 WHEN p.psiquiatrica_depressao = '2' THEN 'Yes'
						 WHEN p.psiquiatrica_panico = '2'    THEN 'Yes'
						 WHEN p.psiquiatrica_ansiedade = '2' THEN 'Yes'
						 WHEN p.psiquiatrica_bipolar = '2'   THEN 'Yes'
						 ELSE 'No'
					 END AS med_psychiatric_disease
					 ,CASE p.psiquiatrica_depressao WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_psychiatric_depression
					 ,CASE p.psiquiatrica_panico    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_psychiatric_panic
					 ,CASE p.psiquiatrica_ansiedade WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_psychiatric_anxiety
					 ,CASE p.psiquiatrica_bipolar   WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_psychiatric_bipolar
					 -- Risco Médico: Doenças Gastrointestinais
					 ,CASE
						 WHEN p.doenca_gastrointestinal = '2'            THEN 'Yes'
						 WHEN p.gastro_cirrose_fibrose_esteatose = '2'   THEN 'Yes'
						 WHEN p.gastro_hepatite = '2'                    THEN 'Yes'
						 WHEN p.gastro_pancreatite = '2'                 THEN 'Yes'
						 WHEN p.gastro_colite = '2'                      THEN 'Yes'
						 WHEN p.gastro_chron = '2'                       THEN 'Yes'
						 WHEN p.gastro_gastrite_esofagite_refluxo = '2'  THEN 'Yes'
						 WHEN p.gastro_ulcera_gastrica = '2'             THEN 'Yes'
						 WHEN p.gastro_diverticulite_diverticulose = '2' THEN 'Yes'
						 ELSE 'No'
					 END AS med_gastrointestinal_disease
					 ,CASE p.gastro_cirrose_fibrose_esteatose   WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_cirrhosis_fibrosis_steatosis
					 ,CASE p.gastro_hepatite                    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_hepatitis
					 ,CASE p.gastro_pancreatite                 WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_pancreatitis
					 ,CASE p.gastro_colite                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_colitis
					 ,CASE p.gastro_chron                       WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_chron
					 ,CASE p.gastro_gastrite_esofagite_refluxo  WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_gastritis_esophagitis_reflux
					 ,CASE p.gastro_ulcera_gastrica             WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_gastric_ulcer
					 ,CASE p.gastro_diverticulite_diverticulose WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gastro_diverticulitis_diverticulosis
					 -- Risco Médico: Doenças Reumáticas ou Ortopédicas
					 ,CASE
						 WHEN p.doenca_reumatica_ou_ortopedica = '2' THEN 'Yes'
						 WHEN p.reumat_artrite_artrose = '2'         THEN 'Yes'
						 WHEN p.reumat_hernia_protusao_discal = '2'  THEN 'Yes'
						 WHEN p.reumat_fibromialgia = '2'            THEN 'Yes'
						 WHEN p.reumat_ler = '2'                     THEN 'Yes'
						 WHEN p.reumat_lupus = '2'                   THEN 'Yes'
						 ELSE 'No'
					 END AS med_rheumatic_or_orthopedic_disease
					 ,CASE p.reumat_artrite_artrose        WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_rheumat_arthritis_arthrosis
					 ,CASE p.reumat_hernia_protusao_discal WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_rheumat_hernia_or_spinal_disc_herniation
					 ,CASE p.reumat_fibromialgia           WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_rheumat_fibromyalgia
					 ,CASE p.reumat_ler                    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_rheumat_rsi
					 ,CASE p.reumat_lupus                  WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_rheumat_lupus
					 -- Risco Médico: Doenças no Sangue
					 ,CASE
						 WHEN p.doenca_sangue = '2'    THEN 'Yes'
						 WHEN p.sangue_anemia = '2'    THEN 'Yes'
						 WHEN p.sangue_hemofilia = '2' THEN 'Yes'
						 ELSE 'No'
					 END AS med_blood_disease
					 ,CASE p.sangue_anemia    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_blood_anemia
					 ,CASE p.sangue_hemofilia WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_blood_haemophilia
					 -- Risco Médico: Doenças Visuais ou Auditivas
					 ,CASE
						 WHEN p.doenca_visual_ou_auditiva = '2'                           THEN 'Yes'
						 WHEN p.visual_miopia_astigmatismo_hipermetropia_presbiopia = '2' THEN 'Yes'
						 WHEN p.visual_glaucoma = '2'                                     THEN 'Yes'
						 WHEN p.visual_descolamento_retina = '2'                          THEN 'Yes'
						 WHEN p.visual_cegueira = '2'                                     THEN 'Yes'
						 WHEN p.auditiva_surdez = '2'                                     THEN 'Yes'
						 ELSE 'No'
					 END AS med_visual_or_hearing_disease
					 ,CASE p.visual_miopia_astigmatismo_hipermetropia_presbiopia WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_visual_myopia_astigmatism_hypermetropia_presbyopia
					 ,CASE p.visual_glaucoma                                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_visual_glaucoma
					 ,CASE p.visual_descolamento_retina                          WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_visual_retinal_detachment
					 ,CASE p.visual_cegueira                                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_visual_blindness
					 ,CASE p.auditiva_surdez                                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_auditiva_deafness
					 -- Risco Médico: Doenças Renais ou nas Vias Urinárias
					 ,CASE
						 WHEN p.doenca_renal_ou_vias_urinarias = '2'                     THEN 'Yes'
						 WHEN p.renal_nefrite_glomerulonefrite = '2'                     THEN 'Yes'
						 WHEN p.renal_calculo = '2'                                      THEN 'Yes'
						 WHEN p.renal_doenca_renal_policistica = '2'                     THEN 'Yes'
						 WHEN p.renal_ma_formacao_congenita = '2'                        THEN 'Yes'
						 WHEN p.vias_urinarias_cistite = '2'                             THEN 'Yes'
						 WHEN p.vias_urinarias_uretrite_ou_infeccao_trato_urinario = '2' THEN 'Yes'
						 ELSE 'No'
					 END AS med_kidney_or_urinary_disease
					 ,CASE p.renal_nefrite_glomerulonefrite                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_kidney_nephritis_glomerulonephritis
					 ,CASE p.renal_calculo                                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_kidney_stone
					 ,CASE p.renal_doenca_renal_policistica                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_kidney_policystic_kidney_disease
					 ,CASE p.renal_ma_formacao_congenita                        WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_kidney_congenital_anomalies
					 ,CASE p.vias_urinarias_cistite                             WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_urinary_cystitis
					 ,CASE p.vias_urinarias_uretrite_ou_infeccao_trato_urinario WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_urinary_uretritis_or_urinary_tract_infection
					 -- Risco Médico: Doenças Infecciosas
					 ,CASE
						 WHEN p.doencas_infecciosas = '2'           THEN 'Yes'
						 WHEN p.infecciosa_hiv = '2'                THEN 'Yes'
						 WHEN p.infecciosa_sifilis = '2'            THEN 'Yes'
						 WHEN p.infecciosa_gonorreia = '2'          THEN 'Yes'
						 WHEN p.covid_19 = '2'                      THEN 'Yes'
						 WHEN p.infecciosa_dengue_hemorragica = '2' THEN 'Yes'
						 ELSE 'No'
					 END AS med_infectious_disease
					 ,CASE p.infecciosa_hiv                WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_infect_aids
					 ,CASE p.infecciosa_sifilis            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_infect_syphilis
					 ,CASE p.infecciosa_gonorreia          WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_infect_gonorrhea
					 ,CASE p.covid_19                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_infect_covid_19
					 ,CASE p.infecciosa_dengue_hemorragica WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_infect_haemorrhagic_dengue
					 -- Risco Médico: Doenças Ginecológicas ou nas Genitais
					 ,CASE
						 WHEN p.doencas_ginecologicas_genitais = '2'           THEN 'Yes'
						 WHEN p.ginecologica_doenca_inflamatoria_pelvica = '2' THEN 'Yes'
						 WHEN p.ginecologica_nodulo_mamario = '2'              THEN 'Yes'
						 WHEN p.genital_endometriose = '2'                     THEN 'Yes'
						 WHEN p.genital_cisto_ovarios = '2'                    THEN 'Yes'
						 WHEN p.genital_prostatite = '2'                       THEN 'Yes'
						 ELSE 'No'
					 END AS med_gynecologic_or_urologyc_disease
					 ,CASE p.ginecologica_doenca_inflamatoria_pelvica WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_pelvic_inflammatory_disease
					 ,CASE p.ginecologica_nodulo_mamario              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_breast_lump
					 ,CASE p.genital_endometriose                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_endometriosis
					 ,CASE p.genital_cisto_ovarios                    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_cystic_ovaries
					 ,CASE p.genital_prostatite                       WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_urol_prostatitis
					 -- Dados Enriquecidos junto ao Birô de Dados
					 --,NULL model_rating_employment_stability AS biro_employment_stability
					 --,NULL bboost_city                       AS biro_city
					 --,NULL bboost_state                      AS biro_state
					 --,NULL collection_occ                    AS biro_collection_occ
					 --,NULL collection_origins                AS biro_collection_origins
					 --,NULL schooling_integrated              AS biro_schooling_integrated
					 --,NULL income_integrated                 AS biro_income_integrated
					 --,NULL bb.total_assets                   AS biro_total_assets
					 
/* Código Município do IBGE */
					 ,codMunicipioIBGE AS prod_codMunicipioIBGE
					 ,codMunicipioIBGE  AS biro_codMunicipioIBGE
				FROM aggregator.pred_vida_proddb_wide        AS p
		  -- LEFT JOIN aggregator.pred_vida_bboost_wide        AS bb  ON p.__company_id =  bb.company_id AND p.__applicant_id =  bb.applicant_id
          LEFT JOIN aggregator.pred_vida_proddb_cities      AS cit ON p.__company_id = cit.company_id AND p.__applicant_id = cit.applicant_id
           LEFT JOIN aggregator.pred_vida_proddb_occupations AS ocp ON p.__company_id = ocp.company_id AND p.__applicant_id = ocp.applicant_id;

UPDATE aggregator.pred_vida_proddb_wide
SET salary = CASE 
    WHEN TRIM(salary) = '' THEN NULL
    WHEN TRIM(salary) ~ '^[0-9.,]+$' THEN REGEXP_REPLACE(REGEXP_REPLACE(TRIM(salary), '\.', '', 'g'), ',', '', 'g')
    ELSE NULL
END;

UPDATE aggregator.pred_vida_proddb_wide
SET peso = CASE 
    WHEN TRIM(peso) ~ '^\d+,\d+$' THEN REPLACE(TRIM(peso), ',', '.')  -- Substituir vírgula por ponto
    WHEN TRIM(peso) ~ '^\d+\.?\d*( kg|)$' THEN REGEXP_REPLACE(TRIM(peso), '[^0-9.]', '', 'g')  -- Remover palavras
    WHEN TRIM(peso) ~ '^\d+\.?\d*$' THEN TRIM(peso)                  -- Manter números com ponto ou inteiros
    ELSE NULL                                            -- Substituir frases por NULL
END;
UPDATE aggregator.pred_vida_proddb_wide
SET altura = CASE 
    WHEN TRIM(altura) ~ '^\d+,\d+$' THEN REPLACE(TRIM(altura), ',', '.')  -- Substituir vírgula por ponto
    WHEN TRIM(altura) ~ '^\d+\.?\d*( cm|)$' THEN REGEXP_REPLACE(TRIM(altura), '[^0-9.]', '', 'g')  -- Remover palavras
    WHEN TRIM(altura) ~ '^\d+\.?\d*$' THEN TRIM(altura)                   -- Manter números com ponto ou inteiros
    ELSE NULL                                                 -- Substituir frases por NULL
END;
UPDATE aggregator.pred_vida_proddb_wide
SET imc = CASE 
    WHEN TRIM(imc) ~ '^\d+,\d+$' THEN REPLACE(TRIM(imc), ',', '.')  -- Substituir vírgula por ponto
    WHEN TRIM(imc) ~ '^\d+\.?\d*$' THEN TRIM(imc)  -- Manter números com ponto ou inteiros
    ELSE NULL
END;

UPDATE aggregator.pred_vida_proddb_wide
SET capital_value = CASE 
    WHEN TRIM(peso) ~ '^\d+,\d+$' THEN REPLACE(TRIM(capital_value), ',', '.')  -- Substituir vírgula por ponto
    WHEN TRIM(peso) ~ '^\d+\.?\d*( kg|)$' THEN REGEXP_REPLACE(TRIM(capital_value), '[^0-9.]', '', 'g')  -- Remover palavras
    WHEN TRIM(peso) ~ '^\d+\.?\d*$' THEN TRIM(capital_value)                  -- Manter números com ponto ou inteiros
    ELSE NULL                                            -- Substituir frases por NULL
END;

UPDATE aggregator.pred_vida_proddb_wide
SET total_or_partial_permanent_disability_value = 
    CASE 
        WHEN TRIM(total_or_partial_permanent_disability_value) = '0' THEN '0'  -- Manter valores zero
        ELSE REPLACE(TRIM(total_or_partial_permanent_disability_value), ',', '.')  -- Substituir vírgula por ponto
    END;

/*
	Tabela persistente: pred_vida_wide_data_python (usada no modelo refatorado no Python)
	Desempilhada, contendo união dos tratamentos de proddb e bboost
    com nomes de coluna e maioria dos conteúdos relevantes em língua inglesa
	ainda carece do join com os datasets públicos
	cuja chave primária será 'codMunicipioIBGE'
*/

DROP TABLE IF EXISTS aggregator.pred_vida_wide_data_python;

CREATE TABLE aggregator.pred_vida_wide_data_python AS
	SELECT
    -- Identificação do proponente
    p.__company_id AS company_id,
    p.__applicant_id AS applicant_id,
    CASE
        -- interview_date e finished_date ambas nulas
        WHEN (p.interview_date LIKE '%0000-00-00%' OR p.interview_date IS NULL) AND
             (p.finished_date LIKE '%0000-00-00%' OR p.finished_date IS NULL)
        THEN NULL
        -- interview_date nula e finished_date não nula
        WHEN (p.interview_date LIKE '%0000-00-00%' OR p.interview_date IS NULL) AND
             (p.finished_date NOT LIKE '%0000-00-00%' AND p.finished_date IS NOT NULL)
        THEN p.finished_date
        -- interview_date não nula
        ELSE p.interview_date
    END AS date_of_interview,
    p.birthday AS date_of_birth,

/* 
A função TIMESTAMPDIFF é específica do MySQL e não é suportada no PostgreSQL. 
Substituímos essa função pelo uso de AGE() combinado com EXTRACT(YEAR FROM ...), 
que é a maneira equivalente no PostgreSQL de calcular a diferença de anos entre duas datas. 
*/

   CASE
    WHEN -- birthday nula
        (p.birthday LIKE '%0000-00-00%' OR p.birthday IS NULL) THEN NULL
    WHEN -- interview_date E finished_date ambas nulas
        (p.interview_date LIKE '%0000-00-00%' OR p.interview_date IS NULL) AND
        (p.finished_date LIKE '%0000-00-00%' OR p.finished_date IS NULL)
        THEN NULL
    WHEN -- interview_date nula MAS finished_date e birthday não nulas
        (p.interview_date LIKE '%0000-00-00%' OR p.interview_date IS NULL) AND
        (p.finished_date NOT LIKE '%0000-00-00%' AND p.finished_date IS NOT NULL) AND
        (p.birthday NOT LIKE '%0000-00-00%' AND p.birthday IS NOT NULL)
        THEN EXTRACT(YEAR FROM AGE(p.finished_date::date, p.birthday::date)) 
    WHEN -- finished_date nula MAS interview_date e birthday não nulas
        (p.interview_date NOT LIKE '%0000-00-00%' AND p.interview_date IS NOT NULL) AND
        (p.finished_date LIKE '%0000-00-00%' OR p.finished_date IS NULL) AND
        (p.birthday NOT LIKE '%0000-00-00%' AND p.birthday IS NOT NULL)
        THEN EXTRACT(YEAR FROM AGE(p.interview_date::date, p.birthday::date))
    WHEN -- finished_date, interview_date e birthday não nulas
        (p.interview_date NOT LIKE '%0000-00-00%' AND p.interview_date IS NOT NULL) AND
        (p.finished_date NOT LIKE '%0000-00-00%' AND p.finished_date IS NOT NULL) AND
        (p.birthday NOT LIKE '%0000-00-00%' AND p.birthday IS NOT NULL)
        THEN EXTRACT(YEAR FROM AGE(p.interview_date::date, p.birthday::date))
END AS age_at_interview_date


,CASE p.sex WHEN '2' THEN 'M' ELSE 'F' END AS gender,
(p.salary)::numeric AS monthly_salary_in_BRL_numeric,
ocp.cbo_manual AS occupation_code_cbo, -- reclassificado manualmente
CASE
    WHEN ocp.cbo_luma_udw = 'SIM' THEN 'No'
    WHEN ocp.cbo_luma_udw = 'NAO' THEN 'Yes'
    ELSE NULL
END AS fe_occupation_hazardous, -- regra de decisão do LUMA (Agosto/2020) para profissões
ocp.cbo_gdegrp AS fe_occupation_category, -- Grande Grupo (CBO) usado no Anuário Estatístico
cit.city AS city,
cit.state AS state,
-- identificação do questionário
p.questionnaire_id,
p.questionnaire_name,
CASE p.questionnaire_type
    WHEN '1' THEN 'Complete'
    ELSE 'Reduced'
END AS questionnaire_type,CASE p.questionnaire_status
    WHEN '0' THEN 'Inactive'
    ELSE 'Active'
END AS questionnaire_status,
-- Cobertura de Morte Natural
(p.capital_value)::text as death_sum_insured_in_BRL_char,

/* 
A função + 0E0 para converter valores de string para numéricos não é necessária no PostgreSQL. 
Utilizamos a notação ::numeric para converter os valores salary e capital_value diretamente para numéricos.
*/
REPLACE(
    REPLACE(
        CASE
            WHEN LEFT(RIGHT(p.capital_value, 3), 1) IN ('.', ',') THEN LEFT(p.capital_value, LENGTH(p.capital_value) - 3)
            ELSE p.capital_value
        END, '.', ''), ',', '')::numeric AS death_sum_insured_in_BRL_numeric,
CASE p.capital_status::integer
    WHEN 1 THEN 0
    ELSE 1
END AS death_target,
CASE p.capital_status::integer
    WHEN 1 THEN 'accepted'
    WHEN 2 THEN 'declined'
    WHEN 5 THEN 'loaded'
END AS death_udw_decision
,CASE
    WHEN p.capital_type_loading IS NULL THEN NULL -- sem agravo!
    WHEN p.capital_type_loading = '' THEN NULL -- sem agravo!
    ELSE p.capital_type_loading
END AS death_loading_type,
CASE
    WHEN p.capital_value_loading IS NULL THEN NULL -- sem agravo!
    WHEN p.capital_value_loading = '' THEN NULL -- sem agravo!
    ELSE p.capital_value_loading
END AS death_loading_amount,
-- Cobertura de Invalidez Funcional Permanente por Doença (IFPD)
p.total_or_partial_permanent_disability_value AS tpd_sum_insured_in_BRL_char,
REPLACE(
    REPLACE(
        CASE
            WHEN LEFT(RIGHT(p.total_or_partial_permanent_disability_value, 3), 1) IN ('.', ',') THEN LEFT(p.total_or_partial_permanent_disability_value, LENGTH(p.total_or_partial_permanent_disability_value) - 3)
            ELSE p.total_or_partial_permanent_disability_value
        END, '.', ''), ',', '')::numeric AS tpd_sum_insured_in_BRL_numeric,
	
CASE p.total_or_partial_permanent_disability_status::integer
    WHEN 1 THEN 0
    ELSE 1
END AS tpd_target,

CASE p.total_or_partial_permanent_disability_status::integer
    WHEN 1 THEN 'accepted'
    WHEN 2 THEN 'declined'
    WHEN 5 THEN 'loaded'
END AS tpd_udw_decision

,CASE
    WHEN p.total_or_partial_permanent_disability_type_loading IS NULL THEN NULL -- sem agravo!
    WHEN p.total_or_partial_permanent_disability_type_loading = '' THEN NULL -- sem agravo!
    ELSE p.total_or_partial_permanent_disability_type_loading
END AS tpd_loading_type,
CASE
    WHEN p.total_or_partial_permanent_disability_value_loading IS NULL THEN NULL -- sem agravo!
    WHEN p.total_or_partial_permanent_disability_value_loading = '' THEN NULL -- sem agravo!
    ELSE p.total_or_partial_permanent_disability_value_loading
END AS tpd_loading_amount,
-- Fatores de risco
CASE p.sedentarismo
    WHEN '2' THEN 'Yes'
    WHEN '1' THEN 'No'
    WHEN '0' THEN NULL
END AS risk_factor_sedentarism,
CASE p.alcool
    WHEN '2' THEN 'Yes'
    WHEN '1' THEN 'No'
    WHEN '0' THEN NULL
END AS risk_factor_alcohol_consumption,
CASE p.drogas
    WHEN '2' THEN 'Yes'
    WHEN '1' THEN 'No'
    WHEN '0' THEN NULL
END AS risk_factor_drug_use,
CASE p.tabagismo
    WHEN '2' THEN 'Yes'
    WHEN '1' THEN 'No'
    WHEN '0' THEN NULL
END AS risk_factor_smoking,
CASE p.hipertensao_arterial
    WHEN '2' THEN 'Yes'
    WHEN '1' THEN 'No'
    WHEN '0' THEN NULL
END AS risk_factor_high_blood_pressure,
CASE p.esporte_risco
    WHEN '2' THEN 'Yes'
    WHEN '1' THEN 'No'
    WHEN '0' THEN NULL
END AS risk_factor_hazardous_sports,
-- IMC, altura e peso
p.altura AS height_in_m, -- não tratado
p.peso AS weight_in_kg, -- não tratado
p.imc AS bmi_original, -- não tratado

CASE
    -- altura e peso iguais a zero mas IMC original válido...
    WHEN (COALESCE(p.altura::DECIMAL, 0.0) + COALESCE(p.peso::DECIMAL, 0.0) = 0.0) 
        AND (CAST(p.imc AS DECIMAL(12,2)) BETWEEN 5 AND 200)
        THEN CAST(p.imc AS DECIMAL(12,2))
    -- se altura e/ou peso forem nulos, zerados ou não numéricos...
    WHEN COALESCE(NULLIF(p.altura::TEXT, '')::DECIMAL, 0.0) = 0.0
        OR COALESCE(NULLIF(p.peso::TEXT, '')::DECIMAL, 0.0) = 0.0
        THEN NULL
    -- se altura > 3 e peso < 3 ...
    WHEN COALESCE(NULLIF(p.altura::DECIMAL, 0.0), 0.0) > 3.0
        AND COALESCE(NULLIF(p.peso::DECIMAL, 0.0), 0.0) < 3.0
        THEN ROUND(p.altura::DECIMAL / POWER(p.peso::DECIMAL, 2), 2)
    -- se altura > 3 e peso > 3 ...
    WHEN COALESCE(NULLIF(p.altura::DECIMAL, 0.0), 0.0) > 3.0
        AND COALESCE(NULLIF(p.peso::DECIMAL, 0.0), 0.0) > 3.0
        THEN ROUND(p.peso::DECIMAL / POWER(p.altura::DECIMAL / 100.0, 2), 2)
    -- se 1 < altura < 3 e peso < 300 ...
    WHEN COALESCE(NULLIF(p.altura::DECIMAL, 0.0), 0.0) BETWEEN 1.0 AND 3.0
        AND COALESCE(NULLIF(p.peso::DECIMAL, 0.0), 0.0) < 300.0
        THEN ROUND(p.peso::DECIMAL / POWER(p.altura::DECIMAL, 2), 2)
        -- se altura < 1 e/ou peso > 300, dados foram digitados erroneamente, portanto retorne NULL
        ELSE NULL
END AS bmi_recalculated,

-- Risco Médico: Doenças Circulatórias ou Cardiovasculares
CASE
    WHEN p.doenca_circulatoria_ou_cardiovascular = '2' THEN 'Yes'
    WHEN p.circ_cardio_angina_infarto_aneurisma = '2'  THEN 'Yes'
    WHEN p.circ_cardio_arritmia = '2'                  THEN 'Yes'
    WHEN p.circ_cardio_avc = '2'                       THEN 'Yes'
    WHEN p.circ_cardio_embolia_trombose = '2'          THEN 'Yes'
    WHEN p.circ_cardio_insuficiencia_cardiaca = '2'    THEN 'Yes'
    ELSE 'No'
END AS med_circulatory_or_cardiovascular_disease

,CASE p.circ_cardio_angina_infarto_aneurisma WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_circ_cardio_angina_mi_aneurysm
,CASE p.circ_cardio_arritmia                 WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_circ_cardio_arrhythmia
,CASE p.circ_cardio_avc                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_circ_cardio_cva
,CASE p.circ_cardio_embolia_trombose         WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_circ_cardio_embolism_thrombosis
,CASE p.circ_cardio_insuficiencia_cardiaca   WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_circ_cardio_cardiac_insufficiency

-- Risco Médico: Doenças Respiratórias
,CASE
    WHEN p.doenca_respiratoria = '2'              THEN 'Yes'
    WHEN p.respir_asma_ou_bronquite = '2'         THEN 'Yes'
    WHEN p.respir_dpoc_ou_enfisema_pulmonar = '2' THEN 'Yes'
    WHEN p.respir_tuberculose = '2'               THEN 'Yes'
    ELSE 'No'
END AS med_respiratory_disease

,CASE p.respir_asma_ou_bronquite         WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_respir_ashtma_or_bronchitis
,CASE p.respir_dpoc_ou_enfisema_pulmonar WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_respir_copd_or_pulmonary_emphysema
,CASE p.respir_tuberculose               WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_respir_tuberculosis
-- Risco Médico: Doenças Cancerígenas
,CASE
    WHEN p.doenca_cancer = '2'              THEN 'Yes'
    WHEN p.cancer_linfoma = '2'             THEN 'Yes'
    WHEN p.cancer_linfoma_hodgkin = '2'     THEN 'Yes'
    WHEN p.cancer_linfoma_nao_hodgkin = '2' THEN 'Yes'
    WHEN p.cancer_leucemia = '2'            THEN 'Yes'
    WHEN p.cancer_mama = '2'                THEN 'Yes'
    WHEN p.cancer_ovario = '2'              THEN 'Yes'
    WHEN p.cancer_pulmao = '2'              THEN 'Yes'
    WHEN p.cancer_prostata = '2'            THEN 'Yes'
    WHEN p.cancer_intestino = '2'           THEN 'Yes'
    WHEN p.cancer_figado = '2'              THEN 'Yes'
    WHEN p.cancer_pancreas = '2'            THEN 'Yes'
    WHEN p.cancer_pele = '2'                THEN 'Yes'
    ELSE 'No'
END AS med_cancer_disease
,CASE p.cancer_linfoma             WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_lymphoma
,CASE p.cancer_linfoma_hodgkin     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_lymphoma_hodgkin
,CASE p.cancer_linfoma_nao_hodgkin WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_lymphoma_non_hodgkin
,CASE p.cancer_leucemia            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_leukaemia
,CASE p.cancer_mama                WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_breast
,CASE p.cancer_ovario              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_ovary
,CASE p.cancer_pulmao              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_lung
,CASE p.cancer_prostata            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_prostate
,CASE p.cancer_intestino           WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_intestine
,CASE p.cancer_figado              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_liver
,CASE p.cancer_pancreas            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_pancreas
,CASE p.cancer_pele                WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_cancer_skin

-- Risco Médico: Doenças Endócrinas
,CASE
    WHEN p.doenca_endocrina = '2'                         THEN 'Yes'
    WHEN p.endocr_intolerancia_glicose_pre_diabetes = '2' THEN 'Yes'
    WHEN p.endocr_diabetes = '2'                          THEN 'Yes'
    WHEN p.endocr_hiper_hipo_tireoidismo = '2'            THEN 'Yes'
    WHEN p.endocr_tireoidite_hashimoto = '2'              THEN 'Yes'
    ELSE 'No'
END AS med_endocrine_disease
,CASE p.endocr_intolerancia_glicose_pre_diabetes WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_endocr_glycose_intolerance_pre_diabetes
,CASE p.endocr_diabetes                          WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_endocr_diabetes
,CASE p.endocr_hiper_hipo_tireoidismo            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_endocr_hiper_hypo_thyroidism
,CASE p.endocr_tireoidite_hashimoto              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_endocr_thyroiditis_hashimoto
-- Risco Médico: Doenças Neurológicas
,CASE
    WHEN p.doenca_neurologica = '2'                  THEN 'Yes'
    WHEN p.neuro_esclerose_multipla = '2'            THEN 'Yes'
    WHEN p.neuro_esclerose_lateral_amiotrofica = '2' THEN 'Yes'
    WHEN p.neuro_epilepsia_convulsao = '2'           THEN 'Yes'
    WHEN p.neuro_parkinson = '2'                     THEN 'Yes'
    WHEN p.neuro_alzheimer = '2'                     THEN 'Yes'
    ELSE 'No'
END AS med_neurologic_disease
,CASE p.neuro_esclerose_multipla            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_neuro_multiple_sclerosis
,CASE p.neuro_esclerose_lateral_amiotrofica WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_neuro_amyotrophic_lateral_sclerosis
,CASE p.neuro_epilepsia_convulsao           WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_neuro_epilepsy_convulsion
,CASE p.neuro_parkinson                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_neuro_parkinson
,CASE p.neuro_alzheimer                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_neuro_alzheimer
-- Risco Médico: Doenças Psiquiátricas
,CASE
    WHEN p.doenca_psiquiatrica = '2'    THEN 'Yes'
    WHEN p.psiquiatrica_depressao = '2' THEN 'Yes'
    WHEN p.psiquiatrica_panico = '2'    THEN 'Yes'
    WHEN p.psiquiatrica_ansiedade = '2' THEN 'Yes'
    WHEN p.psiquiatrica_bipolar = '2'   THEN 'Yes'
    ELSE 'No'
END AS med_psychiatric_disease
,CASE p.psiquiatrica_depressao WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_psychiatric_depression
,CASE p.psiquiatrica_panico    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_psychiatric_panic
,CASE p.psiquiatrica_ansiedade WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_psychiatric_anxiety
,CASE p.psiquiatrica_bipolar   WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_psychiatric_bipolar

-- Risco Médico: Doenças Gastrointestinais
,CASE
    WHEN p.doenca_gastrointestinal = '2'            THEN 'Yes'
    WHEN p.gastro_cirrose_fibrose_esteatose = '2'   THEN 'Yes'
    WHEN p.gastro_hepatite = '2'                    THEN 'Yes'
    WHEN p.gastro_pancreatite = '2'                 THEN 'Yes'
    WHEN p.gastro_colite = '2'                      THEN 'Yes'
    WHEN p.gastro_chron = '2'                       THEN 'Yes'
    WHEN p.gastro_gastrite_esofagite_refluxo = '2'  THEN 'Yes'
    WHEN p.gastro_ulcera_gastrica = '2'             THEN 'Yes'
    WHEN p.gastro_diverticulite_diverticulose = '2' THEN 'Yes'
    ELSE 'No'
END AS med_gastrointestinal_disease

,CASE p.gastro_cirrose_fibrose_esteatose   WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_cirrhosis_fibrosis_steatosis
,CASE p.gastro_hepatite                    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_hepatitis
,CASE p.gastro_pancreatite                 WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_pancreatitis
,CASE p.gastro_colite                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_colitis
,CASE p.gastro_chron                       WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_chron
,CASE p.gastro_gastrite_esofagite_refluxo  WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_gastritis_esophagitis_reflux
,CASE p.gastro_ulcera_gastrica             WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_gastric_ulcer
,CASE p.gastro_diverticulite_diverticulose WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_gastro_diverticulitis_diverticulosis

-- Risco Médico: Doenças Reumáticas ou Ortopédicas
,CASE
    WHEN p.doenca_reumatica_ou_ortopedica = '2' THEN 'Yes'
    WHEN p.reumat_artrite_artrose = '2'         THEN 'Yes'
    WHEN p.reumat_hernia_protusao_discal = '2'  THEN 'Yes'
    WHEN p.reumat_fibromialgia = '2'            THEN 'Yes'
    WHEN p.reumat_ler = '2'                     THEN 'Yes'
    WHEN p.reumat_lupus = '2'                   THEN 'Yes'
    ELSE 'No'
END AS med_rheumatic_or_orthopedic_disease

,CASE p.reumat_artrite_artrose        WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_rheumat_arthritis_arthrosis
,CASE p.reumat_hernia_protusao_discal WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_rheumat_hernia_or_spinal_disc_herniation
,CASE p.reumat_fibromialgia           WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_rheumat_fibromyalgia
,CASE p.reumat_ler                    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_rheumat_rsi
,CASE p.reumat_lupus                  WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_rheumat_lupus

-- Risco Médico: Doenças no Sangue
,CASE
    WHEN p.doenca_sangue = '2'    THEN 'Yes'
    WHEN p.sangue_anemia = '2'    THEN 'Yes'
    WHEN p.sangue_hemofilia = '2' THEN 'Yes'
    ELSE 'No'
END AS med_blood_disease
,CASE p.sangue_anemia    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_blood_anemia
,CASE p.sangue_hemofilia WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_blood_haemophilia

-- Risco Médico: Doenças Visuais ou Auditivas
,CASE
    WHEN p.doenca_visual_ou_auditiva = '2'                           THEN 'Yes'
    WHEN p.visual_miopia_astigmatismo_hipermetropia_presbiopia = '2' THEN 'Yes'
    WHEN p.visual_glaucoma = '2'                                     THEN 'Yes'
    WHEN p.visual_descolamento_retina = '2'                          THEN 'Yes'
    WHEN p.visual_cegueira = '2'                                     THEN 'Yes'
    WHEN p.auditiva_surdez = '2'                                     THEN 'Yes'
    ELSE 'No'
END AS med_visual_or_hearing_disease

,CASE p.visual_miopia_astigmatismo_hipermetropia_presbiopia WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_visual_myopia_astigmatism_hypermetropia_presbyopia
,CASE p.visual_glaucoma                                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_visual_glaucoma
,CASE p.visual_descolamento_retina                          WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_visual_retinal_detachment
,CASE p.visual_cegueira                                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_visual_blindness
,CASE p.auditiva_surdez                                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_auditiva_deafness

-- Risco Médico: Doenças Renais ou nas Vias Urinárias
,CASE
    WHEN p.doenca_renal_ou_vias_urinarias = '2'                     THEN 'Yes'
    WHEN p.renal_nefrite_glomerulonefrite = '2'                     THEN 'Yes'
    WHEN p.renal_calculo = '2'                                      THEN 'Yes'
    WHEN p.renal_doenca_renal_policistica = '2'                     THEN 'Yes'
    WHEN p.renal_ma_formacao_congenita = '2'                        THEN 'Yes'
    WHEN p.vias_urinarias_cistite = '2'                             THEN 'Yes'
    WHEN p.vias_urinarias_uretrite_ou_infeccao_trato_urinario = '2' THEN 'Yes'
    ELSE 'No'
END AS med_kidney_or_urinary_disease
,CASE p.renal_nefrite_glomerulonefrite                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_kidney_nephritis_glomerulonephritis
,CASE p.renal_calculo                                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_kidney_stone
,CASE p.renal_doenca_renal_policistica                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_kidney_policystic_kidney_disease
,CASE p.renal_ma_formacao_congenita                        WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_kidney_congenital_anomalies
,CASE p.vias_urinarias_cistite                             WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_urinary_cystitis
,CASE p.vias_urinarias_uretrite_ou_infeccao_trato_urinario WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_urinary_uretritis_or_urinary_tract_infection

-- Risco Médico: Doenças Infecciosas
,CASE
    WHEN p.doencas_infecciosas = '2'           THEN 'Yes'
    WHEN p.infecciosa_hiv = '2'                THEN 'Yes'
    WHEN p.infecciosa_sifilis = '2'            THEN 'Yes'
    WHEN p.infecciosa_gonorreia = '2'          THEN 'Yes'
    WHEN p.covid_19 = '2'                      THEN 'Yes'
    WHEN p.infecciosa_dengue_hemorragica = '2' THEN 'Yes'
    ELSE 'No'
END AS med

,CASE p.infecciosa_hiv                WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_infect_aids
,CASE p.infecciosa_sifilis            WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_infect_syphilis
,CASE p.infecciosa_gonorreia          WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_infect_gonorrhea
,CASE p.covid_19                      WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_infect_covid_19
,CASE p.infecciosa_dengue_hemorragica WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' ELSE NULL END AS med_infect_haemorrhagic_dengue

,CASE
     WHEN p.doencas_ginecologicas_genitais = '2'           THEN 'Yes'
     WHEN p.ginecologica_doenca_inflamatoria_pelvica = '2' THEN 'Yes'
     WHEN p.ginecologica_nodulo_mamario = '2'              THEN 'Yes'
     WHEN p.genital_endometriose = '2'                     THEN 'Yes'
     WHEN p.genital_cisto_ovarios = '2'                    THEN 'Yes'
     WHEN p.genital_prostatite = '2'                       THEN 'Yes'
     ELSE 'No'
END AS med_gynecologic_or_genital_disease

,CASE p.ginecologica_doenca_inflamatoria_pelvica WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_inflammatory_pelvic_disease
,CASE p.ginecologica_nodulo_mamario              WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_breast_lump
,CASE p.genital_endometriose                     WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_endometriosis
,CASE p.genital_cisto_ovarios                    WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_gynec_cystic_ovaries
,CASE p.genital_prostatite                       WHEN '2' THEN 'Yes' WHEN '1' THEN 'No' WHEN '0' THEN NULL END AS med_urol_prostatitis

-- Dados Enriquecidos junto ao Birô de Dados
,null AS biro_employment_stability
,null                       AS biro_city
,null                      AS biro_state
,null                    AS biro_collection_occ
,null                AS biro_collection_origins
,null              AS biro_scholing_integrated
,null                 AS biro_income_integrated
,null                      AS biro_total_assets
-- Código Município do IBGE
,codMunicipioIBGE AS prod_codMunicipioIBGE
,codMunicipioIBGE  AS biro_codMunicipioIBGE
FROM aggregator.pred_vida_proddb_wide        AS p
-- LEFT JOIN aggregator.pred_vida_bboost_wide        AS bb  ON p.__company_id =  bb.company_id AND p.__applicant_id =  bb.applicant_id
LEFT JOIN aggregator.pred_vida_proddb_cities      AS cit ON p.__company_id = cit.company_id AND p.__applicant_id = cit.applicant_id
LEFT JOIN aggregator.pred_vida_proddb_occupations AS ocp ON p.__company_id = ocp.company_id AND p.__applicant_id = ocp.applicant_id;

ALTER TABLE aggregator.pred_vida_wide_data_python
ADD COLUMN codMunicipioIBGE VARCHAR(7),

-- Fonte: Atlas da Violencia (public_dbs.atlas_violencia) via codMunicipioIBGE
ADD COLUMN city_pub_var_gunshot_death_rate DOUBLE PRECISION,  -- tarmafo
ADD COLUMN city_pub_var_homicide_rate DOUBLE PRECISION,       -- thomic
ADD COLUMN city_pub_var_suicide_rate DOUBLE PRECISION,        -- tsuicid
ADD COLUMN city_pub_var_violent_deaths_rate DOUBLE PRECISION, -- tmortvi

-- Fonte: Atlas Brasil 2013 (public_dbs.atlas_brasil_2013) via codMunicipioIBGE
ADD COLUMN city_pub_var_life_expectancy DOUBLE PRECISION, -- espvida
ADD COLUMN city_pub_var_gini DOUBLE PRECISION,
ADD COLUMN city_pub_var_r1040 DOUBLE PRECISION,
ADD COLUMN city_pub_var_rdpct DOUBLE PRECISION,
ADD COLUMN city_pub_var_sewage DOUBLE PRECISION,
ADD COLUMN city_pub_var_idhm DOUBLE PRECISION,

-- Imputações de valores
ADD COLUMN fe_monthly_salary_in_BRL DOUBLE PRECISION,    -- salario_imputado
ADD COLUMN fe_bmi DOUBLE PRECISION,                      -- IMC_imputado
ADD COLUMN fe_bmi_who_range VARCHAR(30),                 -- IMC_imputado_faixa_WHO
ADD COLUMN fe_age_at_interview_date DOUBLE PRECISION,    -- idade_imputado
ADD COLUMN fe_qx DOUBLE PRECISION,                       -- qx_idade_imputado
ADD COLUMN fe_death_sum_insured_in_BRL DOUBLE PRECISION, -- cob_morte_capital_segurado_imputado
ADD COLUMN fe_tpd_sum_insured_in_BRL DOUBLE PRECISION,   -- cob_ifpd_capital_segurado_imputado

-- Fatores (feature engineering)
ADD COLUMN fe_factor_death_sum_insured_div_salary DOUBLE PRECISION,
ADD COLUMN fe_factor_death_risk_premium_div_salary DOUBLE PRECISION,
ADD COLUMN fe_factor_tpd_sum_insured_div_salary DOUBLE PRECISION,
ADD COLUMN fe_factor_tpd_risk_premium_div_salary DOUBLE PRECISION;

/* índice para agilizar todas as queries daqui em diante */
CREATE INDEX idx_pred_vida_wide
ON aggregator.pred_vida_wide_data_python(company_id, applicant_id, age_at_interview_date);

/* imputações manuais na pred_vida_wide_data_python */
/* 
   variável: codMunicipioIBGE
   imputada pela complementação de bboost.codMunicipioIBGE usando a moda (valor mais frequente)
*/

DO $$  -- Início do bloco anônimo PL/pgSQL
DECLARE
    ibge_moda VARCHAR(7);  -- Declaração da variável local
BEGIN
    -- Consulta para encontrar a moda
    SELECT moda INTO ibge_moda
    FROM (
        SELECT prod_codMunicipioIBGE AS moda, COUNT(*) AS freq
        FROM aggregator.pred_vida_wide_data_python
        WHERE prod_codMunicipioIBGE IS NOT NULL
        GROUP BY 1
        ORDER BY 2 DESC
        LIMIT 1	  
    ) AS dd;
    -- Atualização usando a variável encontrada
    UPDATE aggregator.pred_vida_wide_data_python AS p
    SET codMunicipioIBGE = COALESCE(p.prod_codMunicipioIBGE, p.biro_codMunicipioIBGE, ibge_moda);
END $$;

-- Atualização das variáveis trazidas via LEFT JOIN na tabela atlas_violencia_wide
UPDATE aggregator.pred_vida_wide_data_python AS pvwd
SET city_pub_var_gunshot_death_rate = atlvio.TARMAFO,
    city_pub_var_homicide_rate = atlvio.THOMIC,
    city_pub_var_suicide_rate = atlvio.TSUICID,
    city_pub_var_violent_deaths_rate = atlvio.TMORTVI
FROM public_dbs.atlas_violencia_wide AS atlvio
WHERE pvwd.codMunicipioIBGE = atlvio.codMunicipioIBGE;

-- Atualização das variáveis trazidas via LEFT JOIN na tabela atlas_brasil_2013
UPDATE aggregator.pred_vida_wide_data_python AS pvwd
SET city_pub_var_life_expectancy = atlbr.espvida,
    city_pub_var_gini = atlbr.gini,
    city_pub_var_r1040 = atlbr.r1040,
    city_pub_var_rdpct = atlbr.rdpct,
    city_pub_var_sewage = atlbr.agua_esgoto,
    city_pub_var_idhm = atlbr.idhm
FROM public_dbs.atlas_brasil_2013 AS atlbr
WHERE pvwd.codMunicipioIBGE = atlbr.codmunicipioibge::VARCHAR;

-- Atualização da variável salario imputada pela mediana
UPDATE aggregator.pred_vida_wide_data_python AS pvwd
SET fe_monthly_salary_in_BRL = COALESCE(monthly_salary_in_BRL_numeric,
                                        (SELECT AVG(d.monthly_salary_in_BRL_numeric)
                                         FROM aggregator.pred_vida_wide_data_python AS d
                                         WHERE d.monthly_salary_in_BRL_numeric >= 500
                                           AND d.monthly_salary_in_BRL_numeric <= 500000));

-- Atualização da variável indice_massa_corporea_recalculado imputada pela mediana
UPDATE aggregator.pred_vida_wide_data_python AS pvwd
SET fe_bmi = CASE
                WHEN bmi_recalculated > 10 THEN bmi_recalculated
                ELSE (SELECT AVG(d.bmi_recalculated)
                      FROM aggregator.pred_vida_wide_data_python AS d
                      WHERE d.bmi_recalculated > 10)
            END;

-- Atualização da variável fe_bmi_who_range
UPDATE aggregator.pred_vida_wide_data_python
SET fe_bmi_who_range = CASE
                            WHEN fe_bmi <  18.5 THEN '0_Underweight'
                            WHEN fe_bmi >= 18.5 AND fe_bmi < 25.0 THEN '1_Normal_Weight'
                            WHEN fe_bmi >= 25.0 AND fe_bmi < 30.0 THEN '2_Pre_obesity'
                            WHEN fe_bmi >= 30.0 AND fe_bmi < 35.0 THEN '3_Obesity_Class_I'
                            WHEN fe_bmi >= 35.0 AND fe_bmi < 40.0 THEN '4_Obesity_Class_II'
                            WHEN fe_bmi >= 40.0 THEN '5_Obesity_Class_III' 
                        END;

-- Atualização da variável idade na data da entrevista imputada pela mediana
UPDATE aggregator.pred_vida_wide_data_python AS pvwd
SET fe_age_at_interview_date = CASE
                                  WHEN age_at_interview_date BETWEEN 16 AND 113 THEN age_at_interview_date
                                  ELSE (SELECT AVG(d.age_at_interview_date)
                                        FROM aggregator.pred_vida_wide_data_python AS d
                                        WHERE d.age_at_interview_date BETWEEN 16 AND 113)
                              END;

-- Eliminação da tabela se ela existir
DROP TABLE IF EXISTS aggregator.qx_aux;

-- Criação da tabela qx_aux com os dados selecionados
CREATE TEMP TABLE qx_aux AS
    SELECT age, gender, qx
    FROM public_dbs.biometric_tables
    WHERE NAME = 'BREMS2015';

-- Atualização dos dados em pred_vida_wide_data_python usando qx_aux
UPDATE aggregator.pred_vida_wide_data_python AS pvwd
SET fe_qx = qx
FROM qx_aux AS bt
WHERE pvwd.fe_age_at_interview_date = bt.age
AND pvwd.gender = bt.gender;

-- Eliminação da tabela qx_aux
DROP TABLE IF EXISTS qx_aux;

/* 
   variável: cob_morte_capital_segurado
   imputada pela mediana
*/

DO $$
DECLARE 
    cob_morte_mediana NUMERIC; -- Variável para armazenar a mediana do capital segurado para morte
    cob_ifpd_mediana NUMERIC; -- Variável para armazenar a mediana do capital segurado para invalidez total ou permanente
BEGIN
    /* cob_morte_capital_segurado */
    -- Calcula a mediana do capital segurado para morte
    SELECT AVG(dd.death_sum_insured_in_BRL_numeric)
    INTO cob_morte_mediana
    FROM (
        SELECT d.death_sum_insured_in_BRL_numeric, ROW_NUMBER() OVER (ORDER BY d.death_sum_insured_in_BRL_numeric) as row_number
        FROM aggregator.pred_vida_wide_data_python d
        WHERE d.death_sum_insured_in_BRL_numeric > 1000
    ) as dd
    WHERE dd.row_number IN (
        FLOOR((SELECT COUNT(*) FROM aggregator.pred_vida_wide_data_python WHERE death_sum_insured_in_BRL_numeric > 1000) + 1) / 2,
        FLOOR((SELECT COUNT(*) FROM aggregator.pred_vida_wide_data_python WHERE death_sum_insured_in_BRL_numeric > 1000) + 2) / 2
    );

    /* Atualiza fe_death_sum_insured_in_BRL */
    -- Atualiza o campo fe_death_sum_insured_in_BRL com a mediana calculada
    UPDATE aggregator.pred_vida_wide_data_python
    SET fe_death_sum_insured_in_BRL = CASE
        WHEN death_sum_insured_in_BRL_numeric > 1000 THEN death_sum_insured_in_BRL_numeric
        ELSE cob_morte_mediana
    END;

    /* fatores cob_morte_capital_segurado */
    -- Calcula e atualiza os fatores relacionados ao capital segurado para morte
    UPDATE aggregator.pred_vida_wide_data_python
    SET fe_factor_death_sum_insured_div_salary = CASE
            WHEN fe_monthly_salary_in_BRL = 0 OR fe_monthly_salary_in_BRL IS NULL THEN NULL
            ELSE fe_death_sum_insured_in_BRL / fe_monthly_salary_in_BRL
        END,
        fe_factor_death_risk_premium_div_salary = CASE
            WHEN fe_monthly_salary_in_BRL = 0 OR fe_monthly_salary_in_BRL IS NULL THEN NULL
            ELSE (fe_death_sum_insured_in_BRL * fe_qx) / fe_monthly_salary_in_BRL
        END;

    /* cob_ifpd_capital_segurado */
    -- Calcula a mediana do capital segurado para invalidez total ou permanente
    SELECT AVG(dd.tpd_sum_insured_in_BRL_numeric)
    INTO cob_ifpd_mediana
    FROM (
        SELECT d.tpd_sum_insured_in_BRL_numeric, ROW_NUMBER() OVER (ORDER BY d.tpd_sum_insured_in_BRL_numeric) as row_number
        FROM aggregator.pred_vida_wide_data_python d
        WHERE d.tpd_sum_insured_in_BRL_numeric > 1000
    ) as dd
    WHERE dd.row_number IN (
        FLOOR((SELECT COUNT(*) FROM aggregator.pred_vida_wide_data_python WHERE tpd_sum_insured_in_BRL_numeric > 1000) + 1) / 2,
        FLOOR((SELECT COUNT(*) FROM aggregator.pred_vida_wide_data_python WHERE tpd_sum_insured_in_BRL_numeric > 1000) + 2) / 2
    );

    /* Atualiza fe_tpd_sum_insured_in_BRL */
    -- Atualiza o campo fe_tpd_sum_insured_in_BRL com a mediana calculada
    UPDATE aggregator.pred_vida_wide_data_python
    SET fe_tpd_sum_insured_in_BRL = CASE
            WHEN tpd_sum_insured_in_BRL_numeric > 1000 THEN tpd_sum_insured_in_BRL_numeric
            WHEN tpd_udw_decision IS NOT NULL THEN cob_ifpd_mediana
            ELSE NULL
        END;

    /* fatores cob_ifpd_capital_segurado */
    -- Calcula e atualiza os fatores relacionados ao capital segurado para invalidez total ou permanente
    UPDATE aggregator.pred_vida_wide_data_python
    SET fe_factor_tpd_sum_insured_div_salary = CASE
            WHEN fe_monthly_salary_in_BRL = 0 OR fe_monthly_salary_in_BRL IS NULL THEN NULL
            ELSE fe_tpd_sum_insured_in_BRL / fe_monthly_salary_in_BRL
        END,
        fe_factor_tpd_risk_premium_div_salary = CASE
            WHEN fe_monthly_salary_in_BRL = 0 OR fe_monthly_salary_in_BRL IS NULL THEN NULL
            ELSE (fe_tpd_sum_insured_in_BRL * fe_qx) / fe_monthly_salary_in_BRL
        END;
END $$;


/* 
   Exclui tabelas temporárias e necessárias para a base
   de produção no formato desempilhado
*/
-- DROP TABLE IF EXISTS aggregator.pred_vida_bboost_wide;
DROP TABLE IF EXISTS aggregator.pred_vida_proddb_wide;